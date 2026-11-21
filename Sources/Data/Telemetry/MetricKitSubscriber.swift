import Foundation
#if os(iOS) && canImport(MetricKit)
import MetricKit

/// Native Apple MetricKit subscriber for OS-level performance metrics and hang diagnostics.
/// Zero overhead, non-intrusive, automatically aggregates hangs, CPU exceptions, and daily payloads.
@available(iOS 14.0, *)
public final class DuloMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    public static let shared = DuloMetricKitSubscriber()

    private override init() {
        super.init()
    }

    public func start() {
        MXMetricManager.shared.add(self)
    }

    public func stop() {
        MXMetricManager.shared.remove(self)
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                RemoteTelemetryExporter.shared.submit(event: [
                    "event_type": "metrickit_metric_payload",
                    "payload": json
                ])
            }
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                RemoteTelemetryExporter.shared.submit(event: [
                    "event_type": "metrickit_diagnostic_payload",
                    "payload": json
                ])
            }
        }
    }
}
#endif
