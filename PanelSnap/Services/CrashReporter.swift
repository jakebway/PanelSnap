import Foundation
import MetricKit

/// Saves the system's crash reports for this app (delivered by MetricKit on the next launch) into
/// Files › On My iPhone › PanelSnap › Crash Reports, so they can be shared to diagnose a crash.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    func start() {
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads)
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.filter { !($0.crashDiagnostics ?? []).isEmpty || !($0.hangDiagnostics ?? []).isEmpty }
        guard !crashes.isEmpty,
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = docs.appendingPathComponent("Crash Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        for p in crashes {
            let name = "crash " + f.string(from: p.timeStampEnd) + ".json"
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { try? p.jsonRepresentation().write(to: url) }
        }
    }
}
