import XCTest

#if canImport(UIKit)
@testable import Dulo
#else
@testable import DuloCore
#endif

/// Telemetry spool + uploader: caps, crash safety, batching and the
/// delete-only-on-2xx rule. No network: the uploader is handed a fake transport
/// and the spool is handed a throwaway directory.
final class TelemetrySpoolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("telemetry-spspool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory = directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeSpool(
        maxBytes: Int = 1_000_000,
        maxEvents: Int = 5_000,
        maxRecordBytes: Int = 64 * 1024
    ) -> TelemetrySpool {
        TelemetrySpool(
            directory: directory,
            configuration: TelemetrySpool.Configuration(
                maxBytes: maxBytes,
                maxEvents: maxEvents,
                maxRecordBytes: maxRecordBytes
            )
        )
    }

    private func makeHeader() -> TelemetryHeader {
        TelemetryHeader(
            appVersion: "0.2.2",
            buildNumber: "43",
            versionTag: "v0.2.2 (43)",
            deviceModel: "iPhone8,2",
            osVersion: "15.8.8",
            platform: "ios",
            experimentID: "production-sticky",
            experimentVariant: "sticky",
            launchSeq: 7,
            stickyPrewarm: true,
            prewarmThresholdPages: 0.25
        )
    }

    /// Raw payload keeps these tests about the spool, not about a product event.
    private func makeEvent(
        _ eventID: String,
        padding: Int = 0
    ) -> TelemetryEvent {
        var fields: [String: TelemetryValue] = [:]
        if padding > 0 {
            fields["padding"] = .string(String(repeating: "x", count: padding))
        }
        return TelemetryEvent(
            RawTelemetryPayload(eventType: "test_event", fields: fields),
            header: makeHeader(),
            sessionID: "test-session",
            eventID: eventID,
            ts: 1_700_000_000
        )
    }

    private func eventIDs(in spool: TelemetrySpool, limit: Int = 1_000) -> [String] {
        spool.peekBatch(limit: limit, maxBytes: 10_000_000).map { $0.eventID }
    }

    /// Simulates bytes landing on disk without going through the spool (a torn
    /// write, or a line from an older build).
    private func appendRaw(_ bytes: Data, to url: URL) throws {
        var existing = try Data(contentsOf: url)
        existing.append(bytes)
        try existing.write(to: url)
    }

    private func jsonArrayCount(_ body: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let array = object as? [Any]
        else { return -1 }
        return array.count
    }

    // MARK: - Surviving a relaunch

    func testAppendSurvivesRelaunch() {
        let spool = makeSpool()
        spool.appendSynchronously(makeEvent("e1"))
        spool.appendSynchronously(makeEvent("e2"))
        spool.appendSynchronously(makeEvent("e3"))
        XCTAssertEqual(spool.eventCount, 3)

        // A brand-new instance over the same directory is what a relaunch looks like.
        let relaunched = makeSpool()
        XCTAssertEqual(relaunched.eventCount, 3)
        XCTAssertEqual(eventIDs(in: relaunched), ["e1", "e2", "e3"])
    }

    func testSpoolFileIsNewlineTerminatedJSONL() throws {
        let spool = makeSpool()
        for index in 1...5 {
            spool.appendSynchronously(makeEvent("e\(index)"))
        }

        let data = try Data(contentsOf: spool.fileURL)
        XCTAssertTrue(data.last == 0x0A, "JSONL must end on a record boundary")

        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 5)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line)))
        }
    }

    // MARK: - Caps (drop-oldest)

    func testCountCapDropsOldest() {
        let spool = makeSpool(maxEvents: 10)
        for index in 1...25 {
            spool.appendSynchronously(makeEvent("e\(index)"))
        }

        let ids = eventIDs(in: spool)
        XCTAssertLessThanOrEqual(spool.eventCount, 10)
        XCTAssertGreaterThan(spool.eventCount, 0)
        XCTAssertEqual(ids.last, "e25", "the newest event must survive")
        XCTAssertFalse(ids.contains("e1"), "drop-oldest means the oldest event goes first")

        // Whatever survived must still be the newest contiguous run.
        let expected = (1...25).map { "e\($0)" }
        XCTAssertEqual(ids, Array(expected.suffix(ids.count)))
    }

    func testByteCapDropsOldest() {
        let spool = makeSpool(maxBytes: 2_000, maxEvents: 5_000)
        for index in 1...20 {
            spool.appendSynchronously(makeEvent("e\(index)", padding: 200))
        }

        XCTAssertLessThanOrEqual(spool.byteSize, 2_000)
        XCTAssertLessThan(spool.eventCount, 20)
        XCTAssertEqual(eventIDs(in: spool).last, "e20")
    }

    func testOversizedRecordIsRejectedInsteadOfEvictingTheSpool() {
        let spool = makeSpool(maxRecordBytes: 700)
        spool.appendSynchronously(makeEvent("small"))
        spool.appendSynchronously(makeEvent("huge", padding: 8_000))

        XCTAssertEqual(eventIDs(in: spool), ["small"])
        XCTAssertEqual(spool.rejectedRecordCount, 1)
    }

    // MARK: - Crash safety

    func testPartialTrailingLineIsRepairedOnNextLaunch() throws {
        let spool = makeSpool()
        spool.appendSynchronously(makeEvent("e1"))
        spool.appendSynchronously(makeEvent("e2"))

        // Exactly what a kill -9 during a write leaves behind.
        try appendRaw(Data("{\"event_id\":\"e3\",\"event_type\":\"test_ev".utf8), to: spool.fileURL)

        let relaunched = makeSpool()
        XCTAssertEqual(eventIDs(in: relaunched), ["e1", "e2"])

        // And the repaired file is writable again.
        relaunched.appendSynchronously(makeEvent("e4"))
        XCTAssertEqual(eventIDs(in: relaunched), ["e1", "e2", "e4"])
    }

    func testGarbageLineCannotBlockTheQueue() throws {
        let spool = makeSpool()
        spool.appendSynchronously(makeEvent("e1"))
        // A complete line that is not a JSON object: it can never be uploaded or
        // acknowledged, so the spool must drop it rather than wedge behind it.
        try appendRaw(Data("not json\n".utf8), to: spool.fileURL)
        spool.appendSynchronously(makeEvent("e2"))

        let relaunched = makeSpool()
        XCTAssertEqual(eventIDs(in: relaunched), ["e1", "e2"])
    }

    // MARK: - Reading and acknowledging

    func testPeekBatchDoesNotDeleteAndRespectsLimit() {
        let spool = makeSpool()
        for index in 1...60 {
            spool.appendSynchronously(makeEvent("e\(index)"))
        }

        let batch = spool.peekBatch(limit: 50, maxBytes: 10_000_000)
        XCTAssertEqual(batch.count, 50)
        XCTAssertEqual(batch.first?.eventID, "e1")
        XCTAssertEqual(batch.last?.eventID, "e50")
        XCTAssertEqual(spool.eventCount, 60, "peek must never delete")

        XCTAssertEqual(spool.peekBatch(limit: 50, maxBytes: 10_000_000).count, 50)
    }

    func testSelectBatchRespectsLimitsAndByteBudget() {
        let records = [
            TelemetrySpoolRecord(eventID: "a", line: Data(repeating: 0x61, count: 100)),
            TelemetrySpoolRecord(eventID: "b", line: Data(repeating: 0x62, count: 100)),
            TelemetrySpoolRecord(eventID: "c", line: Data(repeating: 0x63, count: 100))
        ]

        XCTAssertEqual(
            TelemetrySpool.selectBatch(from: records, limit: 50, maxBytes: 1_000).map { $0.eventID },
            ["a", "b", "c"]
        )
        XCTAssertEqual(
            TelemetrySpool.selectBatch(from: records, limit: 2, maxBytes: 1_000).map { $0.eventID },
            ["a", "b"]
        )
        XCTAssertEqual(
            TelemetrySpool.selectBatch(from: records, limit: 50, maxBytes: 150).map { $0.eventID },
            ["a"]
        )
        XCTAssertEqual(
            TelemetrySpool.selectBatch(from: records, limit: 0, maxBytes: 1_000).count,
            0
        )

        // A single record larger than the budget still has to go out, otherwise
        // the spool never drains.
        let huge = [TelemetrySpoolRecord(eventID: "h", line: Data(repeating: 0x68, count: 5_000))]
        XCTAssertEqual(
            TelemetrySpool.selectBatch(from: huge, limit: 50, maxBytes: 100).map { $0.eventID },
            ["h"]
        )
    }

    func testAcknowledgeRemovesOnlyAcknowledgedEvents() {
        let spool = makeSpool()
        ["e1", "e2", "e3", "e4"].forEach { spool.appendSynchronously(makeEvent($0)) }

        let removed = spool.acknowledge(eventIDs: ["e2", "e4"])

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(eventIDs(in: spool), ["e1", "e3"])
        // Acknowledging unknown ids is a no-op, not a wipe.
        XCTAssertEqual(spool.acknowledge(eventIDs: ["nope"]), 0)
        XCTAssertEqual(eventIDs(in: spool), ["e1", "e3"])
    }

    // MARK: - Uploader: delete only on 2xx

    private func makeUploader(
        spool: TelemetrySpool,
        transport: FakeTransport,
        batchLimit: Int = 50
    ) -> TelemetryUploader {
        TelemetryUploader(
            spool: spool,
            transport: transport,
            configuration: TelemetryUploader.Configuration(
                baseURL: URL(string: "http://127.0.0.1:8082")!,
                batchLimit: batchLimit,
                batchByteLimit: 10_000_000
            )
        )
    }

    func testUploaderDeletesEventsOn2xx() async {
        let spool = makeSpool()
        let transport = FakeTransport(outcomes: [.status(200)])
        let uploader = makeUploader(spool: spool, transport: transport)
        ["e1", "e2"].forEach { spool.appendSynchronously(makeEvent($0)) }

        await uploader.flush()

        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertEqual(spool.eventCount, 0, "2xx means the sink has them: delete")
        XCTAssertEqual(uploader.consecutiveFailures, 0)
        XCTAssertEqual(transport.urls.first?.path, "/api/telemetry")
    }

    func testUploaderDeletesOnAny2xx() async {
        let spool = makeSpool()
        let transport = FakeTransport(outcomes: [.status(204)])
        let uploader = makeUploader(spool: spool, transport: transport)
        spool.appendSynchronously(makeEvent("e1"))

        await uploader.flush()

        XCTAssertEqual(spool.eventCount, 0)
    }

    func testUploaderKeepsEventsOn5xx() async {
        let spool = makeSpool()
        let transport = FakeTransport(outcomes: [.status(500)])
        let uploader = makeUploader(spool: spool, transport: transport)
        ["e1", "e2"].forEach { spool.appendSynchronously(makeEvent($0)) }

        await uploader.flush()

        XCTAssertEqual(spool.eventCount, 2, "a server error must never delete")
        XCTAssertEqual(uploader.consecutiveFailures, 1)
    }

    func testUploaderKeepsEventsWhenTheNetworkFails() async {
        let spool = makeSpool()
        let transport = FakeTransport(outcomes: [.failure])
        let uploader = makeUploader(spool: spool, transport: transport)
        spool.appendSynchronously(makeEvent("e1"))

        await uploader.flush()

        XCTAssertEqual(spool.eventCount, 1)
        XCTAssertEqual(uploader.consecutiveFailures, 1)
    }

    func testUploaderDropsUnparseablePayloadsOnly() async {
        let spool = makeSpool()
        let transport = FakeTransport(outcomes: [.status(413)])
        let uploader = makeUploader(spool: spool, transport: transport)
        spool.appendSynchronously(makeEvent("e1"))

        await uploader.flush()

        XCTAssertEqual(spool.eventCount, 0, "payload-shape rejections cannot be retried")
        XCTAssertEqual(uploader.droppedBatchCount, 1)
        XCTAssertEqual(uploader.consecutiveFailures, 0)
    }

    func testUploaderBatchesAtMostFiftyEvents() async {
        let spool = makeSpool()
        let transport = FakeTransport(outcomes: [.status(200)])
        let uploader = makeUploader(spool: spool, transport: transport)
        for index in 1...120 {
            spool.appendSynchronously(makeEvent("e\(index)"))
        }

        await uploader.flush()

        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertEqual(jsonArrayCount(transport.bodies[0]), 50)
        XCTAssertEqual(spool.eventCount, 70)
    }

    func testUploaderPausesWhileBackgrounded() async {
        let spool = makeSpool()
        let transport = FakeTransport(outcomes: [.status(200)])
        let uploader = makeUploader(spool: spool, transport: transport)
        spool.appendSynchronously(makeEvent("e1"))

        uploader.pause()
        await uploader.flush()
        XCTAssertTrue(transport.bodies.isEmpty, "backgrounded apps do not upload")
        XCTAssertEqual(spool.eventCount, 1)

        uploader.resume()
        await uploader.flush()
        XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertEqual(spool.eventCount, 0)
    }

    // MARK: - Schema

    func testEventEncodesFlatSnakeCaseEnvelope() throws {
        let event = TelemetryEvent(
            ResolveTelemetry(
                videoID: "v9",
                transport: .slim,
                status: 200,
                durationMs: 42.5,
                failure: nil,
                priority: 1,
                forced: true
            ),
            header: makeHeader(),
            sessionID: "s1",
            eventID: "id-1",
            ts: 1_700_000_000
        )

        let line = try event.encodedLine()
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return XCTFail("event must encode as a single flat JSON object")
        }

        XCTAssertEqual(object["event_id"] as? String, "id-1")
        XCTAssertEqual(object["event_type"] as? String, "resolve")
        XCTAssertEqual(object["session_id"] as? String, "s1")
        XCTAssertEqual(object["ts"] as? Double, 1_700_000_000)
        XCTAssertEqual(object["video_id"] as? String, "v9")
        XCTAssertEqual(object["transport"] as? String, "slim")
        XCTAssertEqual(object["duration_ms"] as? Double, 42.5)
        XCTAssertEqual(object["priority"] as? Int, 1)
        XCTAssertEqual(object["forced"] as? Bool, true)
        XCTAssertNil(object["failure_kind"], "an absent optional must not be written")

        // Header fields travel on every event.
        XCTAssertEqual(object["app_version"] as? String, "0.2.2")
        XCTAssertEqual(object["build_number"] as? String, "43")
        XCTAssertEqual(object["platform"] as? String, "ios")
        XCTAssertEqual(object["device_model"] as? String, "iPhone8,2")
        XCTAssertEqual(object["launch_seq"] as? Int, 7)
        XCTAssertEqual(object["experiment_sticky_prewarm"] as? Bool, true)

        // Flat: no nested payload object for the sink to unwrap.
        XCTAssertNil(object["fields"])
        XCTAssertNil(object["payload"])

        // And the line decodes back into the model.
        let decoded = try JSONDecoder().decode(TelemetryEvent.self, from: line)
        XCTAssertEqual(decoded.eventID, "id-1")
        XCTAssertEqual(decoded.eventType, "resolve")
        XCTAssertEqual(decoded.sessionID, "s1")
        XCTAssertEqual(decoded.fields["video_id"]?.stringValue, "v9")
        XCTAssertEqual(decoded.fields["priority"]?.intValue, 1)
        XCTAssertEqual(decoded.fields["duration_ms"]?.doubleValue, 42.5)
    }

    func testManifestFetchFlagsNotModified() {
        let notModified = TelemetryEvent(
            ManifestFetchTelemetry(status: 304, bytes: 0, durationMs: 8, conditional: true),
            header: makeHeader(),
            sessionID: "s1",
            eventID: "m1",
            ts: 0
        )
        XCTAssertEqual(notModified.fields["not_modified"]?.boolValue, true)
        XCTAssertEqual(notModified.fields["conditional"]?.boolValue, true)
        XCTAssertEqual(notModified.fields["status"]?.intValue, 304)

        let fresh = TelemetryEvent(
            ManifestFetchTelemetry(status: 200, bytes: 4_096, durationMs: 120),
            header: makeHeader(),
            sessionID: "s1",
            eventID: "m2",
            ts: 0
        )
        XCTAssertEqual(fresh.fields["not_modified"]?.boolValue, false)
        XCTAssertEqual(fresh.fields["bytes"]?.intValue, 4_096)
        XCTAssertNil(fresh.fields["failure_kind"])
    }

    func testDislikeDerivesOKFromStatus() {
        let accepted = DislikeTelemetry(videoID: "v1", status: 204)
        XCTAssertEqual(accepted.ok, true)

        let rejected = DislikeTelemetry(videoID: "v1", status: 500)
        XCTAssertEqual(rejected.ok, false)
        XCTAssertEqual(rejected.fields["ok"]?.boolValue, false)

        // Fire-and-forget stays unknown rather than claiming success.
        let unknown = DislikeTelemetry(videoID: "v1")
        XCTAssertNil(unknown.ok)
        XCTAssertNil(unknown.fields["ok"])
    }

    func testRetryPolicyBacksOffExponentiallyAndCaps() {
        let policy = TelemetryRetryPolicy(baseDelay: 2, multiplier: 2, maxDelay: 8)

        XCTAssertEqual(policy.delay(forAttempt: 0), 0)
        XCTAssertEqual(policy.delay(forAttempt: 1), 2)
        XCTAssertEqual(policy.delay(forAttempt: 2), 4)
        XCTAssertEqual(policy.delay(forAttempt: 3), 8)
        XCTAssertEqual(policy.delay(forAttempt: 4), 8, "never exceeds maxDelay")
        XCTAssertEqual(policy.delay(forAttempt: 100), 8)
    }

    func testUploadBodyIsAJSONArrayOfSpoolLines() throws {
        let records = [
            TelemetrySpoolRecord(eventID: "e1", line: try makeEvent("e1").encodedLine()),
            TelemetrySpoolRecord(eventID: "e2", line: try makeEvent("e2").encodedLine())
        ]

        let body = TelemetryUploader.encodeBody(records)
        XCTAssertEqual(jsonArrayCount(body), 2)
        XCTAssertTrue(body.first == 0x5B)
        XCTAssertTrue(body.last == 0x5D)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: body))
    }
}

// MARK: - Fake transport

/// No sockets: the uploader only ever sees status codes and errors.
private final class FakeTransport: TelemetryUploadTransport {
    enum Outcome {
        case status(Int)
        case failure
    }

    private var outcomes: [Outcome]
    private(set) var bodies: [Data] = []
    private(set) var urls: [URL] = []

    init(outcomes: [Outcome] = []) {
        self.outcomes = outcomes
    }

    func post(_ body: Data, to url: URL) async throws -> TelemetryHTTPResult {
        bodies.append(body)
        urls.append(url)

        guard !outcomes.isEmpty else {
            return TelemetryHTTPResult(statusCode: 200)
        }
        switch outcomes.removeFirst() {
        case .status(let code):
            return TelemetryHTTPResult(statusCode: code)
        case .failure:
            throw URLError(.notConnectedToInternet)
        }
    }
}
