import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Records

/// One spooled line, exactly as it will be POSTed.
public struct TelemetrySpoolRecord: Equatable {
    /// From the line's `event_id`, so a batch can be acknowledged one record at a time.
    public let eventID: String
    /// One JSON object, UTF-8, no trailing newline.
    public let line: Data

    public init(eventID: String, line: Data) {
        self.eventID = eventID
        self.line = line
    }

    public var byteCount: Int { line.count }
}

// MARK: - Spool

/// Append-only, capped JSONL spool under Application Support.
///
/// The app now resolves media itself, so it keeps working away from home — where
/// `http://192.168.2.3:8082` is unreachable. Telemetry therefore has to be
/// buffered on disk and drained later:
///
///   * **Append-only**: a line is written with `O_APPEND` + `fsync`, never
///     rewritten in place. A kill -9 can only ever damage the *last* line.
///   * **Crash-safe**: on first use the tail is repaired (a partial trailing line
///     is cut back to the last `\n`), so a relaunch starts from a clean file.
///   * **Capped, drop-oldest**: at most `maxBytes` / `maxEvents`. Compaction keeps
///     the newest 75%, which amortises the rewrite instead of doing it per append.
///   * **Atomic compaction**: the rewritten file replaces the old one through
///     `Data.write(options: .atomic)` (temp file + rename in the same directory),
///     so a crash mid-compaction leaves the previous spool intact.
///   * **Never on the main thread**: async appends hop to a `.utility` queue. The
///     only synchronous entry points are the crash handler and tests.
///
/// Durability note: an append is fsynced (the requirement), a compaction is not —
/// losing the last compaction would only lose events that were already delivered
/// or already over cap.
public final class TelemetrySpool {
    public struct Configuration: Equatable {
        /// Hard byte cap for the spool file.
        public var maxBytes: Int
        /// Hard event-count cap for the spool file.
        public var maxEvents: Int
        /// Reject single records bigger than this: one runaway event (a MetricKit
        /// blob) must not evict an entire day of telemetry.
        public var maxRecordBytes: Int
        public var fileName: String

        public init(
            maxBytes: Int = 2_000_000,
            maxEvents: Int = 5_000,
            maxRecordBytes: Int = 64 * 1024,
            fileName: String = "telemetry-spool.jsonl"
        ) {
            self.maxBytes = maxBytes
            self.maxEvents = maxEvents
            self.maxRecordBytes = maxRecordBytes
            self.fileName = fileName
        }
    }

    public let directory: URL
    public let configuration: Configuration

    private let lock = NSRecursiveLock()
    private let ioQueue = DispatchQueue(label: "dev.dulo.telemetry.spool", qos: .utility)

    private var lineCount = 0
    private var rejectedCount = 0
    private var isPrepared = false

    public var fileURL: URL {
        directory.appendingPathComponent(configuration.fileName)
    }

    public init(directory: URL, configuration: Configuration = Configuration()) {
        self.directory = directory
        self.configuration = configuration
    }

    /// The production location: `Application Support/dev.dulo.telemetry/`.
    /// Creating the directory is deferred to the first append, so this is safe to
    /// call from a lazy singleton initializer.
    public static func applicationSupport(
        configuration: Configuration = Configuration()
    ) -> TelemetrySpool {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return TelemetrySpool(
            directory: base.appendingPathComponent("dev.dulo.telemetry", isDirectory: true),
            configuration: configuration
        )
    }

    // MARK: Observability

    /// Events currently on disk.
    public var eventCount: Int {
        locked {
            prepareLocked()
            return lineCount
        }
    }

    public var byteSize: Int {
        locked {
            prepareLocked()
            return currentByteSizeLocked()
        }
    }

    public var isEmpty: Bool { eventCount == 0 }

    /// Records refused because they were too large or not a JSON object.
    public var rejectedRecordCount: Int {
        locked { rejectedCount }
    }

    // MARK: Appending

    /// Fire-and-forget append. Encodes on the caller, does IO on a utility queue.
    public func append(_ event: TelemetryEvent) {
        ioQueue.async { [weak self] in
            self?.appendSynchronously(event)
        }
    }

    /// Convenience for call sites that only have a payload.
    public func append<P: TelemetryPayload>(_ payload: P) {
        append(TelemetryEvent(payload))
    }

    /// Blocking append. Only for the uncaught-exception handler (the process is
    /// about to die, so a queued write would be lost) and for tests.
    public func appendSynchronously(_ event: TelemetryEvent) {
        let encoded = try? event.encodedLine()
        locked {
            prepareLocked()
            guard let line = encoded else {
                rejectedCount += 1
                return
            }
            appendLocked(line: line)
        }
    }

    public func appendSynchronously<P: TelemetryPayload>(_ payload: P) {
        appendSynchronously(TelemetryEvent(payload))
    }

    // MARK: Reading

    /// The next batch to POST, oldest first. Does **not** delete anything — the
    /// uploader acknowledges only after the sink answers 2xx.
    public func peekBatch(
        limit: Int = 50,
        maxBytes: Int = 256 * 1024
    ) -> [TelemetrySpoolRecord] {
        locked { () -> [TelemetrySpoolRecord] in
            prepareLocked()
            guard limit > 0 else { return [] }
            let lines = readLinesLocked()
            var records: [TelemetrySpoolRecord] = []
            var invalidCount = 0

            // Bounded scan: never parse more than a few batches' worth of lines.
            let scanBudget = max(limit * 4, limit + 10)
            var scanned = 0
            for line in lines {
                scanned += 1
                if scanned > scanBudget { break }
                if let eventID = Self.eventID(from: line) {
                    records.append(TelemetrySpoolRecord(eventID: eventID, line: line))
                    if records.count >= limit { break }
                } else {
                    invalidCount += 1
                }
            }

            // Self-heal: a line that is not a JSON object with an `event_id` can
            // never be POSTed or acknowledged, so it must not sit at the head of
            // the queue forever.
            if invalidCount > 0 {
                _ = rewriteLocked(lines.filter { Self.eventID(from: $0) != nil })
            }

            return Self.selectBatch(from: records, limit: limit, maxBytes: maxBytes)
        }
    }

    /// Pure batch selection, so the batching rule is testable without a file.
    /// Always returns at least one record when available, even if it alone
    /// exceeds `maxBytes`: refusing it would wedge the spool forever.
    public static func selectBatch(
        from records: [TelemetrySpoolRecord],
        limit: Int,
        maxBytes: Int
    ) -> [TelemetrySpoolRecord] {
        guard limit > 0 else { return [] }
        var selected: [TelemetrySpoolRecord] = []
        var bytes = 0
        for record in records {
            if selected.count >= limit { break }
            let cost = record.byteCount
            if !selected.isEmpty && bytes + cost > maxBytes { break }
            selected.append(record)
            bytes += cost
        }
        return selected
    }

    /// Removes the records the sink accepted. Anything appended after the peek
    /// survives because removal is by `event_id`, not by position.
    @discardableResult
    public func acknowledge(eventIDs: Set<String>) -> Int {
        guard !eventIDs.isEmpty else { return 0 }
        return locked {
            prepareLocked()
            let lines = readLinesLocked()
            var kept: [Data] = []
            var removed = 0
            for line in lines {
                guard let eventID = Self.eventID(from: line) else { continue }
                if eventIDs.contains(eventID) {
                    removed += 1
                    continue
                }
                kept.append(line)
            }
            if kept.count != lines.count {
                _ = rewriteLocked(kept)
            }
            return removed
        }
    }

    /// Test/debug helper.
    public func removeAll() {
        locked {
            prepareLocked()
            _ = rewriteLocked([])
            rejectedCount = 0
        }
    }

    // MARK: - Preparation

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func prepareLocked() {
        guard !isPrepared else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        #if os(iOS)
        // A local buffer must not land in the user's iCloud backup.
        var backupExcluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? backupExcluded.setResourceValues(values)
        #endif
        repairTailLocked()
        lineCount = readLinesLocked().count
        isPrepared = true
    }

    /// A crash between `write` and the kernel flushing the tail leaves a partial
    /// line. Cut it back so the next append starts a clean record. Uses the same
    /// atomic rename as compaction: a crash during repair keeps the old file.
    private func repairTailLocked() {
        guard let data = try? Data(contentsOf: fileURL),
              !data.isEmpty,
              data.last != 0x0A
        else { return }

        let keep = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let repaired = Data(data.prefix(keep))
        try? repaired.write(to: fileURL, options: .atomic)
    }

    // MARK: - IO

    private func appendLocked(line: Data) {
        guard line.count <= configuration.maxRecordBytes else {
            rejectedCount += 1
            return
        }
        guard Self.isJSONObject(line) else {
            rejectedCount += 1
            return
        }
        var record = line
        record.append(0x0A)
        appendBytesLocked(record)
        lineCount += 1
        enforceCapsLocked()
    }

    /// POSIX `O_APPEND` + `fsync`: the durable path, and the reason a burst of
    /// events cannot corrupt earlier lines.
    private func appendBytesLocked(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let descriptor = fileURL.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        guard descriptor >= 0 else {
            rejectedCount += 1
            return
        }
        defer { close(descriptor) }

        bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        _ = fsync(descriptor)
    }

    private func readLinesLocked() -> [Data] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return data.split(separator: 0x0A).map { Data($0) }
    }

    private func currentByteSizeLocked() -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }

    /// Drop-oldest. Keeps the newest 75% so the rewrite is amortised over many
    /// appends instead of running on every single one once the cap is hit.
    private func enforceCapsLocked() {
        let size = currentByteSizeLocked()
        guard size > configuration.maxBytes || lineCount > configuration.maxEvents else { return }

        let lines = readLinesLocked()
        guard !lines.isEmpty else { return }

        let targetBytes = max(1, configuration.maxBytes * 3 / 4)
        let targetCount = max(1, configuration.maxEvents * 3 / 4)

        var kept: [Data] = []
        var keptBytes = 0
        for line in lines.reversed() {
            let cost = line.count + 1
            if kept.count + 1 > targetCount { break }
            if keptBytes + cost > targetBytes && !kept.isEmpty { break }
            kept.append(line)
            keptBytes += cost
        }
        kept.reverse()

        guard kept.count < lines.count else { return }
        _ = rewriteLocked(kept)
    }

    @discardableResult
    private func rewriteLocked(_ lines: [Data]) -> Bool {
        var payload = Data()
        payload.reserveCapacity(4096)
        for line in lines {
            payload.append(line)
            payload.append(0x0A)
        }
        do {
            // `.atomic` writes a sibling temp file and renames it over the spool,
            // so a crash mid-rewrite leaves the previous file untouched.
            try payload.write(to: fileURL, options: .atomic)
            lineCount = lines.count
            return true
        } catch {
            return false
        }
    }

    // MARK: - Parsing

    static func eventID(from line: Data) -> String? {
        guard let identity = try? JSONDecoder().decode(SpoolLineIdentity.self, from: line),
              !identity.eventID.isEmpty
        else { return nil }
        return identity.eventID
    }

    /// Multi-line JSON would break the JSONL contract: validate the shape before
    /// it reaches the sink.
    static func isJSONObject(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return object is [String: Any]
    }
}

/// Minimal view of a spooled line: the spool only needs the id to ack by identity.
private struct SpoolLineIdentity: Decodable {
    let eventID: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
    }
}
