import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Thread-safe, memory-pressure-aware lease cache with deterministic LRU
/// eviction. `NSCache` does not guarantee access-order eviction, so this cache
/// keeps an explicit oldest-to-newest key list instead.
final class LeaseLruCache<T> {
    static var defaultMaxSize: Int { 1024 }

    private let maxSize: Int
    private let lock = NSLock()
    private var entries: [String: Lease<T>] = [:]
    private var order: [String] = []

    init(maxSize: Int = LeaseLruCache.defaultMaxSize) {
        precondition(maxSize > 0)
        self.maxSize = maxSize

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clear()
        }
        #endif
    }

    var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    subscript(key: String) -> Lease<T>? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        guard entry.isFresh(margin: 0) else {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        touchLocked(key)
        return entry
    }

    func contains(_ key: String) -> Bool {
        self[key] != nil
    }

    func put(key: String, lease: Lease<T>, nowElapsedMs: Int64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = lease
        touchLocked(key)
        while entries.count > maxSize, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    func remove(key: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }

    private func touchLocked(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
