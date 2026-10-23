import Foundation
#if canImport(MetricKit)
import MetricKit

/// Takes the reports MetricKit delivers to the app while Backstage is on, and the ones it kept
/// from the past days. Other listeners, such as a crash reporter, get theirs as before.
final class IOSReportListener: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = IOSReportListener()

    private let store = IOSReportStore.shared

    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        // Delivered while Backstage was off, such as before a TestFlight device was unlocked.
        keep(manager.pastDiagnosticPayloads)
        keep(manager.pastPayloads)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        keep(payloads)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        keep(payloads)
    }

    private func keep(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            store.add(.diagnostics, json: payload.jsonRepresentation())
        }
    }

    private func keep(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            store.add(.metrics, json: payload.jsonRepresentation())
        }
    }
}
#endif
