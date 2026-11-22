import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Lightweight loopback HTTP/1.1 reverse proxy running on `127.0.0.1`.
/// Intercepts video/audio streaming requests from AVPlayer, transparently serves
/// cached slices (e.g. 1MB pre-buffers) from disk with 0ms latency, streams missing
/// chunks from CDN while appending to disk cache, and injects required CDN headers.
public final class LocalMediaProxyServer {
    public static let shared = LocalMediaProxyServer()

    private(set) var port: UInt16 = 0
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let acceptQueue = DispatchQueue(label: "dev.dulo.localMediaProxy.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "dev.dulo.localMediaProxy.client", qos: .userInitiated, attributes: .concurrent)

    private let storage: MediaCacheStorage

    public init(storage: MediaCacheStorage = .shared) {
        self.storage = storage
    }

    /// Starts the loopback proxy server on an OS-assigned ephemeral port.
    public func start() {
        guard !isRunning else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[LocalMediaProxyServer] Failed to create socket")
            return
        }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // Assign dynamic port

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
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
            self?.runAcceptLoop(serverFd: fd)
        }
    }

    /// Converts a remote media URL into a local proxy URL.
    public func proxyUrl(for remoteUrl: URL, cacheKey: String? = nil) -> URL {
        guard isRunning, port > 0 else {
            start()
            if port == 0 { return remoteUrl }
            return proxyUrl(for: remoteUrl, cacheKey: cacheKey)
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
            URLQueryItem(name: "k", value: key)
        ]

        return comps.url ?? remoteUrl
    }

    // MARK: - Socket Accept Loop

    private func runAcceptLoop(serverFd: Int32) {
        while isRunning {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(serverFd, sa, &clientLen)
                }
            }

            guard clientFd >= 0 else {
                if !isRunning { break }
                continue
            }

            // Disable SIGPIPE crash on client disconnect
            var nosigpipe: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

            // Disable Nagle's algorithm (TCP_NODELAY) for instant packet dispatch
            var nodelay: Int32 = 1
            setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))

            // Set send/receive buffer sizes to 256KB for high-throughput loopback transfers
            var bufSize: Int32 = 256 * 1024
            setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

            // Set socket timeouts to 15 seconds
            var tv = timeval(tv_sec: 15, tv_usec: 0)
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
        let bytesRead = recv(clientFd, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0 else { return }

        guard let requestString = String(bytes: buffer[0..<bytesRead], encoding: .utf8) else { return }
        let lines = requestString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return }
        let pathWithQuery = parts[1]

        guard let comps = URLComponents(string: "http://127.0.0.1\(pathWithQuery)") else { return }
        guard let encodedUrl = comps.queryItems?.first(where: { $0.name == "u" })?.value else { return }

        var base64 = encodedUrl
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let rawUrlData = Data(base64Encoded: base64),
              let rawUrlString = String(data: rawUrlData, encoding: .utf8),
              let remoteUrl = URL(string: rawUrlString) else {
            return
        }

        let hintKey = comps.queryItems?.first(where: { $0.name == "k" })?.value
        let cacheKey = MediaCacheKey.compute(url: remoteUrl, hint: hintKey)
        storage.touch(key: cacheKey)

        // Parse Range Header
        var requestedRange: (start: Int64, end: Int64?)?
        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                let rangeVal = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if rangeVal.hasPrefix("bytes=") {
                    let spec = rangeVal.dropFirst(6)
                    let rangeParts = spec.components(separatedBy: "-")
                    if let start = Int64(rangeParts[0]) {
                        let end = rangeParts.count > 1 ? Int64(rangeParts[1]) : nil
                        requestedRange = (start, end)
                    }
                }
            }
        }

        // Determine content length & type
        var meta = storage.metadata(for: cacheKey)
        if meta == nil || meta!.contentLength <= 0 {
            if let probe = preflightProbe(url: remoteUrl) {
                storage.setMetadata(for: cacheKey, contentLength: probe.length, contentType: probe.type)
                meta = storage.metadata(for: cacheKey)
            }
        }

        guard let currentMeta = meta, currentMeta.contentLength > 0 else {
            // Cannot probe upstream; send 502
            let err = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
            sendString(clientFd, err)
            return
        }

        let totalLength = currentMeta.contentLength
        let contentType = currentMeta.contentType.isEmpty ? "video/mp4" : currentMeta.contentType

        let reqStart = requestedRange?.start ?? 0
        let reqEnd = min(requestedRange?.end ?? (totalLength - 1), totalLength - 1)
        guard reqStart <= reqEnd else {
            let err = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(totalLength)\r\n\r\n"
            sendString(clientFd, err)
            return
        }

        let responseLength = reqEnd - reqStart + 1
        let isPartial = requestedRange != nil

        let header = isPartial
            ? "HTTP/1.1 206 Partial Content\r\n" +
              "Content-Type: \(contentType)\r\n" +
              "Content-Range: bytes \(reqStart)-\(reqEnd)/\(totalLength)\r\n" +
              "Content-Length: \(responseLength)\r\n" +
              "Accept-Ranges: bytes\r\n" +
              "Connection: keep-alive\r\n\r\n"
            : "HTTP/1.1 200 OK\r\n" +
              "Content-Type: \(contentType)\r\n" +
              "Content-Length: \(totalLength)\r\n" +
              "Accept-Ranges: bytes\r\n" +
              "Connection: keep-alive\r\n\r\n"

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
                guard let chunk = storage.readData(for: cacheKey, offset: currentOffset, length: toRead) else {
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
        var request = URLRequest(url: remoteUrl, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(MediaNetworkHeaders.douyinUA, forHTTPHeaderField: "User-Agent")
        request.setValue(MediaNetworkHeaders.douyinReferer, forHTTPHeaderField: "Referer")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        var writeOffset = start
        var clientAlive = true

        // Custom delegate handling for streaming chunks
        let streamer = ChunkStreamer { chunk in
            guard clientAlive else { return false }
            if self.sendData(clientFd, chunk) {
                self.storage.writeData(
                    for: cacheKey,
                    data: chunk,
                    offset: writeOffset,
                    contentLength: totalLength,
                    contentType: contentType
                )
                writeOffset += Int64(chunk.count)
                return true
            } else {
                clientAlive = false
                return false
            }
        } onComplete: {
            semaphore.signal()
        }

        let customSession = URLSession(configuration: .ephemeral, delegate: streamer, delegateQueue: nil)
        let streamingTask = customSession.dataTask(with: request)
        streamingTask.resume()

        semaphore.wait()
        customSession.invalidateAndCancel()
    }

    // MARK: - Preflight Probing

    private func preflightProbe(url: URL) -> (length: Int64, type: String)? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue(MediaNetworkHeaders.douyinUA, forHTTPHeaderField: "User-Agent")
        request.setValue(MediaNetworkHeaders.douyinReferer, forHTTPHeaderField: "Referer")
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        var result: (length: Int64, type: String)?

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse else { return }

            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let slashIdx = cr.lastIndex(of: "/") {
                let totalStr = cr[cr.index(after: slashIdx)...].trimmingCharacters(in: .whitespaces)
                if let total = Int64(totalStr) {
                    result = (total, type)
                    return
                }
            }
            if let cl = http.value(forHTTPHeaderField: "Content-Length"), let total = Int64(cl) {
                result = (total, type)
            }
        }
        task.resume()
        semaphore.wait()
        return result
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

            while totalSent < length {
                let sent = send(fd, ptr.advanced(by: totalSent), length - totalSent, 0)
                if sent <= 0 {
                    return false // Broken pipe or socket error
                }
                totalSent += sent
            }
            return true
        }
    }
}

// MARK: - Streaming URLSession Delegate

private final class ChunkStreamer: NSObject, URLSessionDataDelegate {
    private let onChunk: (Data) -> Bool
    private let onComplete: () -> Void

    init(onChunk: @escaping (Data) -> Bool, onComplete: @escaping () -> Void) {
        self.onChunk = onChunk
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let shouldContinue = onChunk(data)
        if !shouldContinue {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete()
    }
}
