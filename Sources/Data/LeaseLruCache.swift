import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Thread-safe, memory-pressure-aware lease cache.
/// Replaces manual doubly-linked-list Android LinkedHashMap emulation.
final class LeaseLruCache<T> {
    private final class WrappedEntry {
        let lease: Lease<T>
        init(_ lease: Lease<T>) { self.lease = lease }
    }

    static var defaultMaxSize: Int { 1024 }

    private let cache = NSCache<NSString, WrappedEntry>()
    private let lock = NSLock()
    private var residentKeys = Set<String>()

    init(maxSize: Int = LeaseLruCache.defaultMaxSize) {
        precondition(maxSize > 0)
        cache.countLimit = maxSize

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
        return residentKeys.count
    }

    subscript(key: String) -> Lease<T>? {
        guard let entry = cache.object(forKey: key as NSString) else {
            lock.lock()
            residentKeys.remove(key)
            lock.unlock()
            return nil
        }
        if !entry.lease.isFresh(margin: 0) {
            cache.removeObject(forKey: key as NSString)
            lock.lock()
            residentKeys.remove(key)
            lock.unlock()
            return nil
        }
        return entry.lease
    }

    func contains(_ key: String) -> Bool {
        self[key] != nil
    }

    func put(key: String, lease: Lease<T>, nowElapsedMs: Int64 = 0) {
        cache.setObject(WrappedEntry(lease), forKey: key as NSString)
        lock.lock()
        residentKeys.insert(key)
        lock.unlock()
    }

    func remove(key: String) {
        cache.removeObject(forKey: key as NSString)
        lock.lock()
        residentKeys.remove(key)
        lock.unlock()
    }

    func clear() {
        cache.removeAllObjects()
        lock.lock()
        residentKeys.removeAll()
        lock.unlock()
    }
}
