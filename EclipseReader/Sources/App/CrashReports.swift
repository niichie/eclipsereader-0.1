import SwiftUI
import MetricKit

/// Keeps the crash and hang reports iOS hands the app (through MetricKit, usually on the next
/// launch after a crash), so they can be shared from Settings › About. Nothing is sent anywhere
/// unless you share a report yourself.
final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReports()
    static let changed = Notification.Name("CrashReportsChanged")

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CrashReports", isDirectory: true)
    }

    func start() {
        MXMetricManager.shared.add(self)
        // Anything iOS already has waiting.
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let wanted = payloads.filter { !($0.crashDiagnostics ?? []).isEmpty || !($0.hangDiagnostics ?? []).isEmpty }
        guard !wanted.isEmpty else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        for payload in wanted {
            let kind = (payload.crashDiagnostics ?? []).isEmpty ? "hang" : "crash"
            let name = "EclipseReader-\(kind)-\(stamp.string(from: payload.timeStampEnd)).json"
                .replacingOccurrences(of: ":", with: "-")
            let url = Self.folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            var report = (try? JSONSerialization.jsonObject(with: payload.jsonRepresentation())) as? [String: Any] ?? [:]
            report["eclipseVersion"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            report["eclipseCommit"] = Bundle.main.object(forInfoDictionaryKey: "EclipseCommit") as? String
            let data = (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])) ?? payload.jsonRepresentation()
            try? data.write(to: url, options: .atomic)
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    static func saved() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    static func clear() {
        try? FileManager.default.removeItem(at: folder)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Settings › About: the crash reports this device has saved, to share with the developer.
struct CrashReportsSection: View {
    @State private var reports = CrashReports.saved()
    var body: some View {
        Section {
            if reports.isEmpty {
                Label("No crash reports", systemImage: "checkmark.seal").foregroundStyle(.secondary)
            } else {
                ForEach(reports, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(Self.title(url), systemImage: "exclamationmark.triangle")
                    }
                }
                Button("Delete crash reports", role: .destructive) { CrashReports.clear() }
            }
        } header: {
            Text("Crash reports")
        } footer: {
            Text("If the app ever closes by itself, iOS passes a report to it the next time it opens (sometimes up to a day later). Tap one to share it. Reports stay on this device unless you share them.")
        }
        .onReceive(NotificationCenter.default.publisher(for: CrashReports.changed)) { _ in reports = CrashReports.saved() }
    }
    private static func title(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "EclipseReader-", with: "")
        return name.hasPrefix("hang") ? "Freeze · " + name.dropFirst(5) : "Crash · " + name.dropFirst(6)
    }
}
