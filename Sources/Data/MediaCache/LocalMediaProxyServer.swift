import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Lightweight loopback HTTP/1.1 reverse proxy running on `127.0.0.1`.
/// Intercepts video/audio streaming requests from AVPlayer, transparently serves
/// cached slices (e.g. 800KB pre-buffers) from disk with 0ms latency, streams missing
/// chunks from CDN while appending to disk cache, and injects required CDN headers.
public final class LocalMediaProxyServer {
    public static let shared = LocalMediaProxyServer()

    public private(set) var port: UInt16 = 0
    private var serverFd: Int32 = -1
    public private(set) var isRunning = false
    private var generation: Int = 0
    private let accessToken = UUID().uuidString
    private let acceptQueue = DispatchQueue(label: "dev.dulo.localMediaProxy.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "dev.dulo.localMediaProxy.client", qos: .userInitiated, attributes: .concurrent)

    private let storage: MediaCacheStorage

    #if canImport(UIKit)
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []
    #endif

    public init(storage: MediaCacheStorage = .shared) {
        self.storage = storage
        setupLifecycleObservers()
    }

    deinit {
        #if canImport(UIKit)
        for obs in lifecycleObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        #endif
        stop()
    }

    private func setupLifecycleObservers() {
        #if canImport(UIKit)
        let o1 = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTaskId)
                self.bgTaskId = .invalid
            }
            self.ensureRunning()
        }

        let o2 = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.ensureRunning()
        }

        let o3 = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.bgTaskId != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTaskId)
            }
            self.bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "dev.dulo.localproxy") { [weak self] in
                guard let self else { return }
                if self.bgTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(self.bgTaskId)
                    self.bgTaskId = .invalid
                }
            }
        }
        lifecycleObservers = [o1, o2, o3]
        #endif
    }

    /// Checks if the listening socket and accept loop are healthy.
    public func isHealthy() -> Bool {
        guard isRunning, serverFd >= 0, port > 0 else { return false }
        let flags = fcntl(serverFd, F_GETFL)
        return flags != -1
    }

    /// Self-healing: if the server was killed or suspended by Darwin kernel, restarts it on the preferred port.
    public func ensureRunning() {
        if !isHealthy() {
            NSLog("[LocalMediaProxyServer] Server not healthy (isRunning=%@, fd=%d, port=%d), restarting...", String(isRunning), serverFd, port)
            restart()
        }
    }

    public func restart() {
        let preferred = port > 0 ? port : nil
        stop()
        start(preferredPort: preferred)
    }

    public func stop() {
        isRunning = false
        generation &+= 1
        if serverFd >= 0 {
            // Wake the blocked accept() before closing so the old loop cannot
            // observe a reused fd from a subsequent start().
            shutdown(serverFd, SHUT_RDWR)
            close(serverFd)
            serverFd = -1
        }
    }

    /// Starts the loopback proxy server on an OS-assigned ephemeral port or preferred port.
    public func start(preferredPort: UInt16? = nil) {
        guard !isRunning || !isHealthy() else { return }
        generation &+= 1
        let loopGeneration = generation

        // Clean up previous dead socket if any
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[LocalMediaProxyServer] Failed to create socket")
            return
        }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif

        let targetPort = preferredPort ?? (self.port > 0 ? self.port : 0)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = targetPort > 0 ? targetPort.bigEndian : 0

        var bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // If binding to preferredPort failed (e.g. port stuck in TIME_WAIT), retry with dynamic port 0
        if bindResult != 0 && targetPort > 0 {
            addr.sin_port = 0
            bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard bindResult == 0 else {
            NSLog("[LocalMediaProxyServer] Failed to bind loopback address")
            close(fd)
            return
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        getsockname(fd, withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &len)

        self.port = UInt16(bigEndian: addr.sin_port)
        guard listen(fd, 64) == 0 else {
            NSLog("[LocalMediaProxyServer] Failed to listen on socket")
            close(fd)
            return
        }

        self.serverFd = fd
        self.isRunning = true
        NSLog("[LocalMediaProxyServer] Started listening on http://127.0.0.1:%d", port)

        acceptQueue.async { [weak self] in
            self?.runAcceptLoop(serverFd: fd, generation: loopGeneration)
        }
    }

    /// Converts a remote media URL into a local proxy URL.
    public func proxyUrl(for remoteUrl: URL, cacheKey: String? = nil) -> URL {
        ensureRunning()
        guard isRunning, port > 0 else {
            return remoteUrl
        }

        // If already a local URL or file URL, return as-is
        if remoteUrl.isFileURL || remoteUrl.host == "127.0.0.1" || remoteUrl.host == "localhost" {
            return remoteUrl
        }

        let rawUrl = remoteUrl.absoluteString
        let base64Url = Data(rawUrl.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let key = cacheKey ?? ""
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(port)
        comps.path = "/stream"
        comps.queryItems = [
            URLQueryItem(name: "u", value: base64Url),
            URLQueryItem(name: "k", value: key),
            URLQueryItem(name: "t", value: accessToken)
        ]

        return comps.url ?? remoteUrl
    }

    // MARK: - Socket Accept Loop

    private func runAcceptLoop(serverFd: Int32, generation loopGeneration: Int) {
        while isRunning,
              loopGeneration == generation,
              serverFd == self.serverFd {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(serverFd, sa, &clientLen)
                }
            }

            guard clientFd >= 0 else {
                // A stop/start cycle bumps the generation and closes this fd.
                // Never continue accepting on a stale or reused descriptor.
                guard isRunning,
                      loopGeneration == generation,
                      serverFd == self.serverFd else { break }
                let err = errno
                if err == EBADF || err == EINVAL || err == ENOTSOCK {
                    NSLog("[LocalMediaProxyServer] Listening socket invalid (%d), breaking accept loop", err)
                    self.isRunning = false
                    self.serverFd = -1
                    break
                }
                usleep(10000)
                continue
            }

            // Disable SIGPIPE crash on client disconnect
            var nosigpipe: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

            // Disable Nagle's algorithm (TCP_NODELAY) for instant packet dispatch
            var nodelay: Int32 = 1
            setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))

            // Set send/receive buffer sizes to 512KB for high-throughput loopback transfers
            var bufSize: Int32 = 512 * 1024
            setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

            // Set socket timeouts to 30 seconds
            var tv = timeval(tv_sec: 30, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            clientQueue.async { [weak self] in
                self?.handleClient(clientFd: clientFd)
            }
        }
    }

    // MARK: - Client Request Handling

    private func handleClient(clientFd: Int32) {
        defer { close(clientFd) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var requestData = Data()
        let headerTerminator = Data("\r\n\r\n".utf8)
        while requestData.count < 16 * 1024 {
            let bytesRead = recv(clientFd, &buffer, buffer.count, 0)
            if bytesRead <= 0 { break }
            requestData.append(contentsOf: buffer[0..<bytesRead])
            if requestData.range(of: headerTerminator) != nil { break }
        }
        guard !requestData.isEmpty,
              let requestString = String(data: requestData, encoding: .utf8) else { return }
        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return }
        let pathWithQuery = parts[1]

        guard let comps = URLComponents(string: "http://127.0.0.1\(pathWithQuery)") else { return }
        guard comps.queryItems?.first(where: { $0.name == "t" })?.value == accessToken else {
            // Reject requests that did not originate from proxyUrl(). This is not
            // authentication, but it prevents unrelated local processes from
            // using Dulo as an open URL proxy by guessing the loopback port.
            return
        }
        guard let encodedUrl = comps.queryItems?.first(where: { $0.name == "u" })?.value else { return }

        var base64 = encodedUrl
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let rawUrlData = Data(base64Encoded: base64),
              let rawUrlString = String(data: rawUrlData, encoding: .utf8),
              let remoteUrl = URL(string: rawUrlString),
              let scheme = remoteUrl.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }

        let hintKey = comps.queryItems?.first(where: { $0.name == "k" })?.value
        let cacheKey = MediaCacheKey.compute(url: remoteUrl, hint: hintKey)
        storage.touch(key: cacheKey)
        storage.pin(key: cacheKey)
        defer {
            storage.unpin(key: cacheKey)
            storage.flushMetadata(for: cacheKey)
        }

        // Coalesce request: cancel active background preload task since player is taking over streaming
        MediaPreloadManager.shared.cancel(key: cacheKey)

        // Parse Range Header (RFC 7233 / RFC 9110)
        var requestedRange: (start: Int64, end: Int64?)?
        var requestedSuffix: Int64?

        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                let rangeVal = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if rangeVal.hasPrefix("bytes=") {
                    let spec = String(rangeVal.dropFirst(6).trimmingCharacters(in: .whitespaces))
                    if spec.hasPrefix("-") {
                        // Suffix range: bytes=-32768 (e.g. AVPlayer requesting MP4 moov atom from EOF)
                        if let suffix = Int64(spec.dropFirst()) {
                            requestedSuffix = suffix
                        }
                    } else {
                        let rangeParts = spec.components(separatedBy: "-")
                        if let start = Int64(rangeParts[0]) {
                            let end = (rangeParts.count > 1 && !rangeParts[1].isEmpty) ? Int64(rangeParts[1]) : nil
                            requestedRange = (start, end)
                        }
                    }
                }
            }
        }

        // Determine content length & type
        var meta = storage.metadata(for: cacheKey)
        if (meta?.contentLength ?? 0) <= 0 {
            if let probe = preflightProbe(url: remoteUrl) {
                storage.setMetadata(for: cacheKey, contentLength: probe.length, contentType: probe.type)
                meta = storage.metadata(for: cacheKey)
            }
        }

        guard let currentMeta = meta, currentMeta.contentLength > 0 else {
            // Cannot probe upstream; send 502 with Connection: close
            let err = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendString(clientFd, err)
            return
        }

        let totalLength = currentMeta.contentLength
        let contentType = currentMeta.contentType.isEmpty ? "video/mp4" : currentMeta.contentType

        let reqStart: Int64
        let reqEnd: Int64
        if let suffix = requestedSuffix {
            reqStart = max(0, totalLength - suffix)
            reqEnd = totalLength - 1
        } else {
            reqStart = requestedRange?.start ?? 0
            reqEnd = min(requestedRange?.end ?? (totalLength - 1), totalLength - 1)
        }

        guard reqStart <= reqEnd else {
            let err = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(totalLength)\r\nConnection: close\r\n\r\n"
            sendString(clientFd, err)
            return
        }

        let responseLength = reqEnd - reqStart + 1
        let isPartial = requestedRange != nil || requestedSuffix != nil

        let header = isPartial
            ? "HTTP/1.1 206 Partial Content\r\n" +
              "Content-Type: \(contentType)\r\n" +
              "Content-Range: bytes \(reqStart)-\(reqEnd)/\(totalLength)\r\n" +
              "Content-Length: \(responseLength)\r\n" +
              "Accept-Ranges: bytes\r\n" +
              "Connection: close\r\n\r\n"
            : "HTTP/1.1 200 OK\r\n" +
              "Content-Type: \(contentType)\r\n" +
              "Content-Length: \(totalLength)\r\n" +
              "Accept-Ranges: bytes\r\n" +
              "Connection: close\r\n\r\n"

        guard sendString(clientFd, header) else { return }
        if parts[0] == "HEAD" { return }

        // Stream Content
        streamContent(
            clientFd: clientFd,
            remoteUrl: remoteUrl,
            cacheKey: cacheKey,
            start: reqStart,
            end: reqEnd,
            totalLength: totalLength,
            contentType: contentType
        )
    }

    private func streamContent(
        clientFd: Int32,
        remoteUrl: URL,
        cacheKey: String,
        start: Int64,
        end: Int64,
        totalLength: Int64,
        contentType: String
    ) {
        var currentOffset = start
        let meta = storage.metadata(for: cacheKey)
        let cachedBytes = meta?.cachedBytes ?? 0

        // 1. Stream from Disk Cache
        if currentOffset < cachedBytes {
            let diskEnd = min(end, cachedBytes - 1)
            let blockSize = 256 * 1024 // 256 KB blocks for high throughput on loopback socket

            if let (fileHandle, availableBytes) = storage.openReadingFileHandle(for: cacheKey) {
                defer { try? fileHandle.close() }
                let effectiveDiskEnd = min(diskEnd, availableBytes - 1)
                do {
                    try fileHandle.seek(toOffset: UInt64(currentOffset))
                    while currentOffset <= effectiveDiskEnd {
                        let toRead = Int(min(Int64(blockSize), effectiveDiskEnd - currentOffset + 1))
                        let chunk = fileHandle.readData(ofLength: toRead)
                        if chunk.isEmpty { break }
                        guard sendData(clientFd, chunk) else { return } // Client disconnected
                        currentOffset += Int64(chunk.count)
                    }
                } catch {
                    // Seek failed; gracefully fall through to readData fallback
                }
            }

            // Fallback for any remaining unstreamed cached bytes
            while currentOffset <= diskEnd {
                let toRead = Int(min(Int64(blockSize), diskEnd - currentOffset + 1))
                guard let chunk = storage.readData(for: cacheKey, offset: currentOffset, length: toRead), !chunk.isEmpty else {
                    break
                }
                guard sendData(clientFd, chunk) else { return } // Client disconnected
                currentOffset += Int64(chunk.count)
            }
        }

        // 2. Stream remaining from Upstream CDN (if not satisfied by disk)
        if currentOffset <= end {
            streamFromCDN(
                clientFd: clientFd,
                remoteUrl: remoteUrl,
                cacheKey: cacheKey,
                start: currentOffset,
                end: end,
                totalLength: totalLength,
                contentType: contentType
            )
        }
    }

    private func streamFromCDN(
        clientFd: Int32,
        remoteUrl: URL,
        cacheKey: String,
        start: Int64,
        end: Int64,
        totalLength: Int64,
        contentType: String
    ) {
        var request = URLRequest(url: remoteUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(MediaNetworkHeaders.douyinUA, forHTTPHeaderField: "User-Agent")
        request.setValue(MediaNetworkHeaders.douyinReferer, forHTTPHeaderField: "Referer")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        var writeOffset = start
        var clientAlive = true
        var isCompleted = false
        var lastActivityTime = Date().timeIntervalSince1970

        var streamingTask: URLSessionDataTask?
        let streamer = ChunkStreamer(expectedStart: start) { [weak self] chunk in
            guard let self, clientAlive else { return false }
            lastActivityTime = Date().timeIntervalSince1970
            if self.sendData(clientFd, chunk) {
                self.storage.writeData(
                    for: cacheKey,
                    data: chunk,
                    offset: writeOffset,
                    contentLength: totalLength,
                    contentType: contentType
                )
                writeOffset += Int64(chunk.count)
                lastActivityTime = Date().timeIntervalSince1970
                return true
            } else {
                clientAlive = false
                streamingTask?.cancel()
                return false
            }
        } onComplete: {
            isCompleted = true
            semaphore.signal()
        }

        let customSession = URLSession(configuration: .ephemeral, delegate: streamer, delegateQueue: nil)
        let task = customSession.dataTask(with: request)
        streamingTask = task
        task.resume()

        // Adaptive Inactivity Watchdog: only cancels if NO data is transferred for 30 consecutive seconds
        while !isCompleted && clientAlive {
            let waitResult = semaphore.wait(timeout: .now() + 2.0)
            if waitResult == .success {
                break
            }
            let idleSeconds = Date().timeIntervalSince1970 - lastActivityTime
            if idleSeconds >= 30.0 {
                task.cancel()
                break
            }
        }

        customSession.invalidateAndCancel()
        storage.flushMetadata(for: cacheKey)
        if streamer.rejected {
            NSLog("[LocalMediaProxyServer] Upstream ignored or mismatched Range for %@ (wanted %lld)", cacheKey, start)
        }
    }

    // MARK: - Preflight Probing

    private func preflightProbe(url: URL) -> (length: Int64, type: String)? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue(MediaNetworkHeaders.douyinUA, forHTTPHeaderField: "User-Agent")
        request.setValue(MediaNetworkHeaders.douyinReferer, forHTTPHeaderField: "Referer")
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        let probe = ResponseProbe(semaphore: semaphore)
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()

        // The delegate cancels the task as soon as response headers arrive, so a
        // server that ignores Range cannot buffer the entire video into memory.
        if semaphore.wait(timeout: .now() + 8.0) == .timedOut {
            task.cancel()
        }
        session.invalidateAndCancel()

        guard let http = probe.response else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
        if let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let slashIdx = cr.lastIndex(of: "/") {
            let totalStr = cr[cr.index(after: slashIdx)...].trimmingCharacters(in: .whitespaces)
            if let total = Int64(totalStr) {
                return (total, type)
            }
        }
        if let cl = http.value(forHTTPHeaderField: "Content-Length"), let total = Int64(cl) {
            return (total, type)
        }
        return nil
    }

    // MARK: - Socket Helpers

    @discardableResult
    private func sendString(_ fd: Int32, _ string: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return sendData(fd, data)
    }

    @discardableResult
    private func sendData(_ fd: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.baseAddress else { return true }
            var totalSent = 0
            let length = data.count
            var pollRetries = 0

            while totalSent < length {
                let sent = send(fd, ptr.advanced(by: totalSent), length - totalSent, 0)
                if sent > 0 {
                    totalSent += sent
                    pollRetries = 0
                } else if sent == 0 {
                    return false
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        pollRetries += 1
                        if pollRetries > 60 { // Saturated or disconnected client timeout
                            return false
                        }
                        // Socket send buffer is full (AVPlayer paused reading or buffer saturated).
                        // Poll with POLLOUT for up to 1000ms.
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let pollRes = poll(&pfd, 1, 1000)
                        if pollRes > 0 {
                            if (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                                return false // Client hung up, broken pipe or socket error
                            }
                            if (pfd.revents & Int16(POLLOUT)) != 0 {
                                usleep(1000) // 1ms sleep prevents zero-sleep spin if socket immediately reports writable
                                continue // Socket is writable again!
                            }
                        } else if pollRes == 0 {
                            // 1 second poll timed out, retry loop while checking socket health
                            continue
                        } else {
                            return false // Socket error or broken pipe
                        }
                    } else if err == EINTR {
                        continue
                    } else {
                        return false // Broken pipe (EPIPE) or connection reset
                    }
                }
            }
            return true
        }
    }
}

// MARK: - Streaming URLSession Delegate

private final class ResponseProbe: NSObject, URLSessionDataDelegate {
    let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var signaled = false
    private(set) var response: HTTPURLResponse?

    init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        completionHandler(.cancel)
        signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        signal()
    }

    private func signal() {
        lock.lock()
        defer { lock.unlock() }
        guard !signaled else { return }
        signaled = true
        semaphore.signal()
    }
}

private final class ChunkStreamer: NSObject, URLSessionDataDelegate {
    private let expectedStart: Int64
    private let onChunk: (Data) -> Bool
    private let onComplete: () -> Void
    private let lock = NSLock()
    private var finished = false
    private(set) var rejected = false

    init(
        expectedStart: Int64,
        onChunk: @escaping (Data) -> Bool,
        onComplete: @escaping () -> Void
    ) {
        self.expectedStart = expectedStart
        self.onChunk = onChunk
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            reject(completionHandler)
            return
        }

        let rangeStart = http.value(forHTTPHeaderField: "Content-Range")
            .flatMap(Self.rangeStart)

        switch http.statusCode {
        case 206 where rangeStart == expectedStart:
            completionHandler(.allow)
        case 200 where expectedStart == 0:
            // A 200 is valid only for a request from byte zero. Any other
            // start means the upstream ignored Range and the bytes would be
            // written to the wrong cache offset.
            completionHandler(.allow)
        default:
            reject(completionHandler)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let blocked = rejected || finished
        lock.unlock()
        guard !blocked else { return }

        let shouldContinue = onChunk(data)
        if !shouldContinue {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private func reject(_ completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        rejected = true
        lock.unlock()
        completionHandler(.cancel)
        finish()
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        onComplete()
    }

    private static func rangeStart(_ header: String) -> Int64? {
        // Expected form: "bytes 123-456/789".
        guard header.lowercased().hasPrefix("bytes ") else { return nil }
        let body = header.dropFirst("bytes ".count)
        guard let dash = body.firstIndex(of: "-") else { return nil }
        return Int64(body[..<dash].trimmingCharacters(in: .whitespaces))
    }
}
