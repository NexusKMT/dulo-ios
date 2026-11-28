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
            if let json = String(data: data, encoding: .utf8) {
                TelemetryUploader.shared.submit(MetricKitTelemetry(kind: .metric, payloadJSON: json))
            }
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            if let json = String(data: data, encoding: .utf8) {
                TelemetryUploader.shared.submit(MetricKitTelemetry(kind: .diagnostic, payloadJSON: json))
            }
        }
    }
}
#endif
