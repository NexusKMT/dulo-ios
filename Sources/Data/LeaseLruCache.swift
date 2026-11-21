/// Access-order lease cache; all reads and writes happen on the main actor
/// (owned by `FeedViewModel`), matching the Android main-thread contract.
/// Evicts expired leases first, then the least recently used beyond `maxSize`.
final class LeaseLruCache<T> {
    private final class Node {
        let key: String
        let lease: Lease<T>
        var prev: Node?
        var next: Node?

        init(key: String, lease: Lease<T>) {
            self.key = key
            self.lease = lease
        }
    }

    static var defaultMaxSize: Int { 1024 }

    private let maxSize: Int
    private var map: [String: Node] = [:]
    /// Doubly-linked list, most recently used at the tail.
    private var head: Node?
    private var tail: Node?

    init(maxSize: Int = LeaseLruCache.defaultMaxSize) {
        precondition(maxSize > 0)
        self.maxSize = maxSize
    }

    var size: Int { map.count }

    subscript(key: String) -> Lease<T>? {
        guard let node = map[key] else { return nil }
        moveToTail(node)
        return node.lease
    }

    func contains(_ key: String) -> Bool {
        map[key] != nil
    }

    /// Removes expired leases first, then keeps the most recently used `maxSize`.
    func put(key: String, lease: Lease<T>, nowElapsedMs: Int64) {
        pruneExpired(nowElapsedMs: nowElapsedMs)
        if let existing = map[key] { unlink(existing) }
        let node = Node(key: key, lease: lease)
        map[key] = node
        append(node)
        while map.count > maxSize, let eldest = head {
            unlink(eldest)
            map.removeValue(forKey: eldest.key)
        }
    }

    private func pruneExpired(nowElapsedMs: Int64) {
        var node = head
        while let current = node {
            node = current.next
            if !current.lease.isFresh(nowElapsedMs: nowElapsedMs, marginMs: 0) {
                unlink(current)
                map.removeValue(forKey: current.key)
            }
        }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func append(_ node: Node) {
        if let tail { tail.next = node; node.prev = tail } else { head = node }
        tail = node
    }

    private func moveToTail(_ node: Node) {
        guard tail !== node else { return }
        unlink(node)
        append(node)
    }
}
