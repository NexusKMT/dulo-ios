import CryptoKit
import Foundation

/// Persistent disk cache for feed images, bounded by total bytes.
///
/// All file operations are serialized on a utility queue and run off the main
/// actor. The cache intentionally uses file modification dates as an
/// approximate LRU signal: reads are not forced to touch metadata, which keeps
/// the hot path cheap on flash storage.
public final class ImageDiskCache {
    public static let shared = ImageDiskCache()

    private let directory: URL
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "dev.dulo.image-disk-cache", qos: .utility)
    private let maxBytes: Int

    public init(
        directoryName: String = "AppImageDiskCache",
        maxBytes: Int = 200 * 1024 * 1024
    ) {
        precondition(maxBytes > 0)
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = base.appendingPathComponent(directoryName, isDirectory: true)
        self.maxBytes = maxBytes
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func diskPath(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash)
    }

    /// Reads raw image data from disk cache.
    public func data(for url: URL) -> Data? {
        ioQueue.sync {
            let path = diskPath(for: url)
            return try? Data(contentsOf: path)
        }
    }

    /// Atomically stores raw image data, then trims the cache if needed.
    public func store(data: Data, for url: URL) {
        guard !data.isEmpty else { return }
        ioQueue.sync {
            let path = diskPath(for: url)
            guard (try? data.write(to: path, options: .atomic)) != nil else { return }
            trimIfNeeded()
        }
    }

    /// Checks if image data exists on disk.
    public func contains(url: URL) -> Bool {
        ioQueue.sync {
            fileManager.fileExists(atPath: diskPath(for: url).path)
        }
    }

    /// Clears all cached disk files.
    public func clearAll() {
        ioQueue.sync {
            try? fileManager.removeItem(at: directory)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func trimIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: Int, modified: Date)] = []
        var total = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
        }

        guard total > maxBytes else { return }

        // Evict oldest 25% headroom rather than deleting one file per write.
        let target = max(0, maxBytes * 3 / 4)
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > target else { break }
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}
