import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Asynchronous, zero-main-thread-overhead batching telemetry exporter.
/// Buffers telemetry events in a fixed-size ring buffer and flushes them to the server.
/// Safe in all environments (if server is unavailable, drops oldest events without blocking).
public final class RemoteTelemetryExporter {
    public static let shared = RemoteTelemetryExporter()

    private let queue = DispatchQueue(label: "dev.dulo.telemetry.exporter", qos: .utility)
    private var buffer: [[String: Any]] = []
    private let maxBufferSize = 512
    private let batchFlushThreshold = 20
    private var flushTimer: DispatchSourceTimer?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 8.0
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    private init() {
        setupFlushTimer()
    }

    public func submit(event: [String: Any]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            var enriched = event
            enriched["app_version"] = AppVersion.marketingVersion
            enriched["build_number"] = AppVersion.buildNumber
            enriched["version_tag"] = AppVersion.displayString
            enriched["device_model"] = AppVersion.deviceModelIdentifier
            #if canImport(UIKit)
            enriched["os_version"] = UIDevice.current.systemVersion
            #endif
            if enriched["timestamp"] == nil {
                enriched["timestamp"] = Date().timeIntervalSince1970
            }

            if self.buffer.count >= self.maxBufferSize {
                self.buffer.removeFirst(50)
            }
            self.buffer.append(enriched)
            if self.buffer.count >= self.batchFlushThreshold {
                self.flushInternal()
            }
        }
    }

    private func setupFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.flushInternal()
        }
        timer.resume()
        self.flushTimer = timer
    }

    private func flushInternal() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        guard let endpoint = URL(string: "\(AppSettings.serverBaseUrl)/api/telemetry"),
              let jsonData = try? JSONSerialization.data(withJSONObject: batch, options: []) else {
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let task = session.dataTask(with: request) { _, _, _ in
            // Fire and forget; never log noise or crash
        }
        task.resume()
    }

    /// Synchronously sends a fatal uncaught exception event to telemetry server before process termination.
    public func exportCrashSynchronously(name: String, reason: String, callStack: String) {
        guard let endpoint = URL(string: "\(AppSettings.serverBaseUrl)/api/telemetry") else { return }
        var payload: [String: Any] = [
            "event_type": "uncaught_exception",
            "exception_name": name,
            "exception_reason": reason,
            "call_stack": callStack,
            "app_version": AppVersion.marketingVersion,
            "build_number": AppVersion.buildNumber,
            "version_tag": AppVersion.displayString,
            "device_model": AppVersion.deviceModelIdentifier,
            "timestamp": Date().timeIntervalSince1970
        ]
        #if canImport(UIKit)
        payload["os_version"] = UIDevice.current.systemVersion
        #endif

        guard let jsonData = try? JSONSerialization.data(withJSONObject: [payload], options: []) else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 3.0)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let sema = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, _, _ in
            sema.signal()
        }
        task.resume()
        _ = sema.wait(timeout: .now() + 2.0)
    }
}
