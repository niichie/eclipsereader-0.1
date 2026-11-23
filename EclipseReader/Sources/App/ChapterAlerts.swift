import Foundation
import UserNotifications
import BackgroundTasks

/// New-chapter alerts: a background check every few hours, a notification per updated series,
/// and the app icon badge showing how many new chapters are waiting.
/// Nonisolated on purpose: the notification calls run off the main actor in one task.
enum ChapterAlerts {
    static let refreshID = "com.personal.eclipse.reader.refresh"

    /// Asks once; returns whether alerts may be shown.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        return granted
    }
    static func authorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Next background check, no sooner than three hours from now (iOS picks the exact time).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
    static func cancelSchedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
    }

    struct Update: Sendable {
        let seriesID: String
        let title: String
        let count: Int
        let latest: String?
    }
    /// One notification per updated series, or a single summary when many updated at once.
    static func post(_ updates: [Update]) async {
        guard !updates.isEmpty, await authorized() else { return }
        let center = UNUserNotificationCenter.current()
        if updates.count > 4 {
            let content = UNMutableNotificationContent()
            let total = updates.reduce(0) { $0 + $1.count }
            content.title = "\(total) new chapters"
            content.body = updates.prefix(6).map(\.title).joined(separator: ", ") + (updates.count > 6 ? "…" : "")
            content.sound = .default
            content.threadIdentifier = "new-chapters"
            try? await center.add(UNNotificationRequest(identifier: "new-\(UUID().uuidString)", content: content, trigger: nil))
            return
        }
        for update in updates {
            let content = UNMutableNotificationContent()
            content.title = update.title
            let latest = update.latest.map { " · \(ChapterText.split($0).name)" } ?? ""
            content.body = update.count == 1 ? "New chapter\(latest)" : "\(update.count) new chapters\(latest)"
            content.sound = .default
            content.threadIdentifier = "new-chapters"
            content.userInfo = ["series": update.seriesID]
            try? await center.add(UNNotificationRequest(identifier: "new-\(update.seriesID)-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
    static func badge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}
