import Foundation

/// OpenAVT backend that forwards events and calculated metrics to Dulo's RemoteTelemetryExporter.
open class OAVTBackendRemote: NSObject, OAVTBackendProtocol {
    public override init() {
        super.init()
    }

    open func sendEvent(event: OAVTEvent) {
        var dict = event.getDictionary()
        dict["event_type"] = "oavt_event"
        dict["action"] = event.getAction().getActionName()
        RemoteTelemetryExporter.shared.submit(event: dict)
    }

    open func sendMetric(metric: OAVTMetric) {
        var dict: [String: Any] = [
            "event_type": "oavt_metric",
            "metric_name": metric.getName(),
        ]
        if let val = metric.getValue().getDoubleValue() {
            dict["metric_value"] = val
        }
        RemoteTelemetryExporter.shared.submit(event: dict)
    }

    open func instrumentReady(instrument: OAVTInstrument) {}
    open func endOfService() {}
}
