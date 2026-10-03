import SwiftUI
import UIKit
import BackgroundTasks
import UserNotifications

// Both the visible update controls and background refresh validate the same release.
enum ReleaseClient {
    static var installedBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    }
    static func latest() async throws -> AppRelease {
        let endpoint = URL(string: "https://api.github.com/repos/joystickgame8333-byte/MajedLive-iOS/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MajedLive-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(AppRelease.self, from: data)
        guard release.build != nil, release.ipa != nil else { throw URLError(.cannotParseResponse) }
        return release
    }
}

enum UpdateNotificationPolicy {
    static func newBuild(_ release: AppRelease, installed: Int, notified: Int) -> Int? {
        guard release.ipa != nil, let build = release.build,
              build > installed, build > notified else { return nil }
        return build
    }
}

@MainActor
final class UpdateNotificationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let notifications = UpdateNotifications.shared
        UNUserNotificationCenter.current().delegate = notifications
        BGTaskScheduler.shared.register(forTaskWithIdentifier: UpdateNotifications.taskID, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in notifications.handle(refresh) }
        }
        return true
    }
}

@MainActor
final class UpdateNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifications()
    nonisolated static let taskID = "com.majedlive.demo.iphone.update-refresh"
    nonisolated static let updateID = "football-update-available"
    nonisolated static let testID = "football-notification-test"
    private static let enabledKey = "updateNotificationsEnabled"
    private static let notifiedKey = "lastNotifiedUpdateBuild"
    private static let checkedKey = "backgroundUpdateLastCheck"
    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: UpdateNotifications.enabledKey)
    @Published private(set) var busy = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var status = "الإشعارات غير مفعّلة."
    @Published var message: String?
    @Published var showUpdateSettings = false
    var lastBackgroundCheck: Date? { defaults.object(forKey: Self.checkedKey) as? Date }

    func refreshStatus() async {
        let settings = await center.notificationSettings()
        permissionDenied = settings.authorizationStatus == .denied
        clearInstalledUpdate()
        if !enabled { status = "الإشعارات غير مفعّلة." }
        else if permissionDenied { status = "اسمح بإشعارات «الكرة عمر» من إعدادات الآيفون." }
        else if UIApplication.shared.backgroundRefreshStatus != .available {
            status = "فعّل تحديث التطبيقات في الخلفية وأوقف نمط الطاقة المنخفضة للفحص بالخلفية."
        } else {
            status = "الفحص مفعّل؛ الآيفون يحدد موعده وقد يتأخر."
            schedule()
        }
    }

    func setEnabled(_ value: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if value {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard allowed else {
                    message = "الإشعارات غير مسموحة. افتح إعدادات الآيفون واسمح بإشعارات «الكرة عمر»."
                    await refreshStatus()
                    return
                }
            } catch {
                message = "تعذّر تفعيل الإشعارات. حاول مجددًا."
                return
            }
        }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if !value {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            center.removePendingNotificationRequests(withIdentifiers: [Self.updateID, Self.testID])
            center.removeDeliveredNotifications(withIdentifiers: [Self.updateID, Self.testID])
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
        await refreshStatus()
    }

    func schedule() {
        guard enabled, UIApplication.shared.backgroundRefreshStatus == .available else { return }
        // Keep the existing request, so opening the app doesn't postpone its earliest start.
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let pending = requests.contains { $0.identifier == Self.taskID }
            Task { @MainActor in
                guard self.enabled, !pending,
                      UIApplication.shared.backgroundRefreshStatus == .available else { return }
                let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
                request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
                do { try BGTaskScheduler.shared.submit(request) }
                catch { self.status = "تعذّرت جدولة الفحص بالخلفية. أعد فتح التطبيق بعد تفعيل تحديث التطبيقات في الخلفية." }
            }
        }
    }

    func handle(_ backgroundTask: BGAppRefreshTask) {
        schedule()
        let operation = Task { @MainActor in
            var succeeded = false
            defer {
                backgroundTask.expirationHandler = nil
                backgroundTask.setTaskCompleted(success: succeeded)
            }
            guard enabled else { succeeded = true; return }
            do {
                let release = try await ReleaseClient.latest()
                try Task.checkCancellation()
                try await notifyIfNeeded(release)
                try Task.checkCancellation()
                defaults.set(Date(), forKey: Self.checkedKey)
                succeeded = true
            } catch { /* Retry on the next system-scheduled refresh. */ }
        }
        backgroundTask.expirationHandler = { operation.cancel() }
    }

    private func notifyIfNeeded(_ release: AppRelease) async throws {
        let settings = await center.notificationSettings()
        try Task.checkCancellation()
        guard enabled, [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus),
              let build = UpdateNotificationPolicy.newBuild(release, installed: ReleaseClient.installedBuild,
                    notified: defaults.integer(forKey: Self.notifiedKey)) else { return }
        let content = UNMutableNotificationContent()
        content.title = "تحديث جديد للكرة عمر"
        content.body = "النسخة \(build) جاهزة. اضغط لفتح شاشة التحديث."
        content.sound = .default
        content.badge = 1
        content.userInfo = ["build": build]
        try await center.add(UNNotificationRequest(identifier: Self.updateID, content: content, trigger: nil))
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: [Self.updateID])
            center.removeDeliveredNotifications(withIdentifiers: [Self.updateID])
            UIApplication.shared.applicationIconBadgeNumber = 0
            return
        }
        // Persist only after delivery was accepted; failures can retry.
        defaults.set(build, forKey: Self.notifiedKey)
    }

    func clearInstalledUpdate() {
        let notified = defaults.integer(forKey: Self.notifiedKey)
        if notified > 0, notified <= ReleaseClient.installedBuild {
            center.removePendingNotificationRequests(withIdentifiers: [Self.updateID])
            center.removeDeliveredNotifications(withIdentifiers: [Self.updateID])
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    func testNotification() async {
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            message = "فعّل إشعارات التحديث واسمح بها أولًا."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "الكرة عمر · تجربة إشعار"
        content.body = "الإشعارات تعمل. هذا اختبار فقط، وليس تحديثًا جديدًا."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: Self.testID, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            message = "سيظهر إشعار تجريبي بعد 5 ثوانٍ. يمكنك قفل الشاشة لتجربته."
        } catch { message = "تعذّر إرسال الإشعار التجريبي." }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.updateID else { return }
        await MainActor.run { self.showUpdateSettings = true }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier == Self.testID ? [.banner, .sound] : []
    }
}

struct UpdateNotificationControls: View {
    @ObservedObject private var notifications = UpdateNotifications.shared
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("إشعارات التحديث", isOn: Binding(get: { notifications.enabled }, set: { value in
                Task { await notifications.setEnabled(value) }
            })).disabled(notifications.busy)
                .accessibilityIdentifier("updateNotificationsToggle")
            Text(notifications.status).font(.caption).foregroundStyle(.secondary)
            Text("الفحص بالخلفية ليس فوريًا أو مضمونًا، وقد يتوقف عند إغلاق التطبيق بالسحب. اترك التطبيق في الخلفية.")
                .font(.caption).foregroundStyle(.secondary)
            if let checked = notifications.lastBackgroundCheck {
                Text("آخر فحص بالخلفية: \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if notifications.enabled {
                Button { Task { await notifications.testNotification() } } label: {
                    Label("تجربة إشعار", systemImage: "bell.badge")
                }.accessibilityIdentifier("testUpdateNotification")
            }
            if notifications.permissionDenied {
                Button("فتح إعدادات الآيفون") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        }.padding(14).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
            .task { await notifications.refreshStatus() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await notifications.refreshStatus() }
            }
            .alert("إشعارات التطبيق", isPresented: Binding(get: { notifications.message != nil }, set: {
                if !$0 { notifications.message = nil }
            })) { Button("حسنًا", role: .cancel) { notifications.message = nil } }
            message: { Text(notifications.message ?? "") }
    }
}
