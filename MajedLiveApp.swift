import SwiftUI
import WebKit
import UIKit
import AVKit

@main
struct MajedLiveApp: App {
    @UIApplicationDelegateAdaptor(UpdateNotificationDelegate.self) private var notificationDelegate
    @StateObject private var updates = AppUpdates()
    @StateObject private var notifications = UpdateNotifications.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = Appearance.automatic.rawValue
    @AppStorage("theme") private var themeName = AppTheme.ruby.rawValue
    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .ruby }

    var body: some Scene {
        WindowGroup {
            FootballShell()
                .environmentObject(updates)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.appTheme, theme)
                .tint(theme.accent)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .sheet(isPresented: $notifications.showUpdateSettings) {
                    SettingsScreen(updates: updates)
                        .environment(\.layoutDirection, .rightToLeft)
                        .environment(\.appTheme, theme)
                        .task { await updates.check() }
                }
                .task { await notifications.refreshStatus() }
                .onChange(of: scenePhase) { phase in
                    if phase == .background { notifications.schedule() }
                    if phase == .active { Task { await notifications.refreshStatus() } }
                }
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "تلقائي حسب الآيفون"
        case .light: return "نهاري"
        case .dark: return "ليلي"
        }
    }
    var symbol: String {
        switch self {
        case .automatic: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case ruby, ocean, emerald
    var id: String { rawValue }
    var title: String {
        switch self { case .ruby: return "عنابي"; case .ocean: return "أزرق"; case .emerald: return "زمردي" }
    }
    private func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    var accent: Color {
        Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch self {
            case .ruby: return self.color(dark ? 0xFF6685 : 0xA60F2E)
            case .ocean: return self.color(dark ? 0x70B9FF : 0x185BA6)
            case .emerald: return self.color(dark ? 0x65DDB4 : 0x067452)
            }
        })
    }
    func accent(dark: Bool) -> Color {
        switch self {
        case .ruby: return Color(uiColor: color(dark ? 0xFF6685 : 0xA60F2E))
        case .ocean: return Color(uiColor: color(dark ? 0x70B9FF : 0x185BA6))
        case .emerald: return Color(uiColor: color(dark ? 0x65DDB4 : 0x067452))
        }
    }
    func background(dark: Bool) -> Color {
        switch self {
        case .ruby: return Color(uiColor: color(dark ? 0x120E12 : 0xFCF4F5))
        case .ocean: return Color(uiColor: color(dark ? 0x0B1420 : 0xF1F6FD))
        case .emerald: return Color(uiColor: color(dark ? 0x0B1915 : 0xF0F8F4))
        }
    }
    func card(dark: Bool) -> Color {
        switch self {
        case .ruby: return Color(uiColor: color(dark ? 0x251B23 : 0xFFFFFF))
        case .ocean: return Color(uiColor: color(dark ? 0x182638 : 0xFFFFFF))
        case .emerald: return Color(uiColor: color(dark ? 0x192D25 : 0xFFFFFF))
        }
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.ruby
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

struct ThemeColors {
    let theme: AppTheme
    let dark: Bool
    var accent: Color { theme.accent(dark: dark) }
    var background: Color { theme.background(dark: dark) }
    var card: Color { theme.card(dark: dark) }
}

enum Site {
    static let origin = URL(string: "https://majed-koora.live/")!
    static func media(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              let url = URL(string: value, relativeTo: origin)?.absoluteURL,
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
    static func date(offset: Int, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        let date = calendar.date(byAdding: .day, value: offset, to: now)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    static func matchesURL(date: String) -> URL {
        var components = URLComponents(url: origin.appendingPathComponent("api/v1/matches"), resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "date", value: date), URLQueryItem(name: "scope", value: "all"), URLQueryItem(name: "lang", value: "ar")]
        return components.url!
    }
}

struct Team: Decodable {
    let name: String
    let logo: String?
    let score: Int?
}

struct Competition: Decodable {
    let id: String?
    var filterKey: String { id.map { "id:" + $0 } ?? "name:" + name }
    let name: String
    let logo: String?
}

struct MatchBroadcast: Decodable {
    let channel: String?
    let commentator: String?
}

enum MatchInformation {
    static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
    static func dateTitle(_ value: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "Asia/Riyadh")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.calendar = parser.calendar
        formatter.locale = Locale(identifier: "ar")
        formatter.timeZone = parser.timeZone
        formatter.dateFormat = "EEEE، d MMMM yyyy"
        return formatter.string(from: date)
    }
}

struct Match: Decodable, Identifiable {
    let id: String
    let provider: String?
    var providerID: String { provider ?? "majed" }
    var providerTitle: String { providerID == "ntv" ? "NTV" : "ماجد لايف" }
    let date: String
    let time: String
    let state: String
    let state_text: String?
    let elapsed_seconds: Int?
    let clock_synced_at: Double?
    let added_minutes: Int?
    let home_team: Team
    let away_team: Team
    let tournament: Competition
    let broadcast: MatchBroadcast?
    let stadium: String?
    let round: String?
    let watch_ready: Bool?
    let watch_available: Bool?
    let site_watch_enabled: Bool?
    let watch_url: String?

    var broadcastChannel: String? { MatchInformation.text(broadcast?.channel) }
    var commentatorName: String? { MatchInformation.text(broadcast?.commentator) }
    var stadiumName: String? { MatchInformation.text(stadium) }
    var roundTitle: String? { MatchInformation.text(round) }

    // Mirror the website's matchAction conditions; never invent a stream URL.
    var playbackURL: URL? {
        guard watch_ready == true, watch_available == true, site_watch_enabled != false,
              let value = watch_url, !value.isEmpty,
              let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    var isLive: Bool { state == "live" || state == "halftime" }
    var hasScore: Bool { (isLive || state == "finished") && (home_team.score != nil || away_team.score != nil) }
    var scoreText: String {
        let home = home_team.score.map(String.init) ?? "—"
        let away = away_team.score.map(String.init) ?? "—"
        return "\(home) : \(away)"
    }
    func clockText(now: Date = Date()) -> String? {
        guard isLive, let elapsed = elapsed_seconds else { return nil }
        let delta: Int
        if state == "live", let synced = clock_synced_at, synced > 0 {
            delta = Int(max(0, now.timeIntervalSince1970 - synced / 1000))
        } else { delta = 0 }
        let seconds = max(0, elapsed) + delta
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

}

enum LeagueFilter {
    static let all = "__all__"
    static func matches(_ matches: [Match], selected: String) -> [Match] {
        selected == all ? matches : matches.filter { $0.tournament.filterKey == selected }
    }
}

struct MatchesResponse: Decodable {
    let success: Bool
    let matches: [Match]?
    let message: String?
}

enum APIError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self { case .server(let message): return message }
    }
}

struct MatchesAPI {
    func load(date: String) async throws -> [Match] {
        var request = URLRequest(url: Site.matchesURL(date: date))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server("تعذّر الاتصال بالموقع. حاول مجددًا.")
        }
        let result = try JSONDecoder().decode(MatchesResponse.self, from: data)
        guard result.success else { throw APIError.server(result.message ?? "تعذّر تحميل المباريات.") }
        guard let matches = result.matches else { throw APIError.server("استجابة الموقع غير مكتملة.") }
        return matches
    }
}

@MainActor
final class ScheduleModel: ObservableObject {
    @Published var matches: [Match] = []
    @Published var loading = false
    @Published var error: String?
    @Published var updated: Date?
    @Published var displayedDate = ""
    private var requestID = UUID()

    func refresh(offset: Int, clear: Bool = false) async {
        let date = Site.date(offset: offset)
        let id = UUID()
        requestID = id
        if clear || date != displayedDate { matches = []; updated = nil }
        loading = true
        error = nil
        let result = await FootballSchedule.load(date: date)
        guard !Task.isCancelled, requestID == id else { return }
        if result.unavailable.count < 2 {
            matches = result.matches
            displayedDate = date
            updated = Date()
        }
        if !result.unavailable.isEmpty {
            error = "تعذّر تحديث " + result.unavailable.joined(separator: " و ") + ". اسحب لإعادة المحاولة."
        }
        if requestID == id { loading = false }
    }
}

struct Playback: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let servers: [StreamServer]
    var providerName = "ماجد لايف"
    var initialServerID: String? = nil
}

struct StreamServer: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String
    let url: String
    let enabled: Bool?
    let is_default: Bool?
    let priority: Int?
    var playbackURL: URL? {
        guard enabled != false, let value = URL(string: url),
              value.scheme == "https", value.host != nil,
              value.user == nil, value.password == nil else { return nil }
        return value
    }
    var nativeVideo: Bool { ["mp4", "m3u8", "hls_js", "dplayer"].contains(type) }
}

struct WatchCard: Decodable {
    struct Watch: Decodable {
        let watch_enabled: Bool
        let available: Bool
        let servers: [StreamServer]
    }
    let success: Bool
    let watch: Watch?
}

struct WatchAPI {
    func servers(publishedURL: URL) async throws -> [StreamServer] {
        guard let key = URLComponents(url: publishedURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "mk" })?.value, !key.isEmpty else {
            throw APIError.server("رابط المشاهدة لا يحتوي بيانات السيرفر. اطلب من صاحب الموقع تفعيل رابط المشغّل.")
        }
        var endpoint = URLComponents(url: Site.origin.appendingPathComponent("api/public/watch-card"), resolvingAgainstBaseURL: false)!
        endpoint.queryItems = [URLQueryItem(name: "key", value: key)]
        var request = URLRequest(url: endpoint.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server("تعذّر تحميل سيرفرات البث.")
        }
        let card = try JSONDecoder().decode(WatchCard.self, from: data)
        guard card.success, let watch = card.watch, watch.watch_enabled, watch.available else {
            throw APIError.server("البث غير متاح حاليًا من المصدر.")
        }
        let servers = watch.servers.filter { $0.playbackURL != nil && ($0.type == "iframe" || $0.nativeVideo) }
            .sorted { ($0.priority ?? 0) < ($1.priority ?? 0) }
        guard !servers.isEmpty else { throw APIError.server("لا يوجد سيرفر يمكن تشغيله داخل التطبيق حاليًا.") }
        return servers
    }
}

struct AppRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var build: Int? {
        guard tag_name.hasPrefix("build-") else { return nil }
        return Int(tag_name.dropFirst(6))
    }
    var ipa: URL? {
        guard !draft, !prerelease,
              let asset = assets.first(where: { $0.name == "MajedLive.ipa" }),
              asset.browser_download_url.scheme == "https",
              asset.browser_download_url.host == "github.com",
              asset.browser_download_url.user == nil, asset.browser_download_url.password == nil,
              asset.browser_download_url.path.hasPrefix("/joystickgame8333-byte/MajedLive-iOS/releases/download/"),
              asset.browser_download_url.lastPathComponent == "MajedLive.ipa" else { return nil }
        return asset.browser_download_url
    }
}

@MainActor
final class AppUpdates: ObservableObject {
    @Published private(set) var available: AppRelease?
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published var notice: String?
    private var lastCheck: Date?
    let installedBuild = ReleaseClient.installedBuild

    func check(manual: Bool = false) async {
        guard !checking else { return }
        if !manual, let lastCheck, Date().timeIntervalSince(lastCheck) < 120 { return }
        lastCheck = Date()
        checking = true
        defer { checking = false }
        do {
            let release = try await ReleaseClient.latest()
            guard !Task.isCancelled else { return }
            guard let build = release.build, release.ipa != nil else {
                if manual { notice = "لم تتوفر نسخة صالحة للتحديث بعد." }
                return
            }
            available = build > installedBuild ? release : nil
            UpdateNotifications.shared.clearInstalledUpdate()
            if manual && available == nil { notice = "أنت تستخدم أحدث نسخة متاحة." }
        } catch {
            if manual && !Task.isCancelled { notice = "تعذّر الاتصال بخدمة التحديثات. تحقق من الإنترنت وحاول مجددًا." }
        }
    }

    func install() {
        guard !installing, let ipa = available?.ipa else { return }
        var components = URLComponents()
        components.scheme = "apple-magnifier"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        guard let target = components.url else { return }
        installing = true
        // TrollStore handles the download and its own installation confirmation.
        UIApplication.shared.open(target, options: [:]) { [weak self] opened in
            Task { @MainActor in
                guard let self else { return }
                self.installing = false
                if !opened { self.notice = "تعذّر فتح TrollStore. فعّل URL Scheme من إعداداته ثم أعد المحاولة." }
            }
        }
    }
}

struct SettingsScreen: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(theme: appTheme, dark: colorScheme == .dark) }
    @ObservedObject var updates: AppUpdates
    var standalone = false
    @AppStorage("appearance") private var appearance = Appearance.automatic.rawValue
    @AppStorage("theme") private var themeName = AppTheme.ruby.rawValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    appearancePicker
                    themePicker
                    UpdateNotificationControls()
                    updateControls
                }.padding(20)
            }
            .background(colors.background)
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if !standalone { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } } }
            .alert("تحديث التطبيق", isPresented: Binding(get: { updates.notice != nil }, set: { if !$0 { updates.notice = nil } })) {
                Button("حسنًا", role: .cancel) { updates.notice = nil }
            } message: { Text(updates.notice ?? "") }
        }
    }
    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ألوان التطبيق").font(.headline)
            Text("كل نمط له مظهر نهاري وليلي؛ اختيارك محفوظ.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(AppTheme.allCases) { option in
                Button { themeName = option.rawValue } label: {
                    HStack(spacing: 12) {
                        ForEach([false, true], id: \.self) { dark in
                            VStack(spacing: 6) {
                                Image(systemName: dark ? "moon.fill" : "sun.max.fill")
                                    .font(.caption).foregroundStyle(option.accent(dark: dark))
                                RoundedRectangle(cornerRadius: 3).fill(option.card(dark: dark))
                                    .frame(width: 28, height: 8)
                            }.frame(width: 46, height: 44)
                                .background(option.background(dark: dark), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Text(option.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Image(systemName: themeName == option.rawValue ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(themeName == option.rawValue ? colors.accent : Color.secondary)
                    }.padding(10)
                        .background(colors.accent.opacity(themeName == option.rawValue ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
                    .accessibilityLabel("نمط " + option.title)
                    .accessibilityValue(themeName == option.rawValue ? "محدد" : "غير محدد")
            }
        }.padding(14).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var updateControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let release = updates.available {
                Label("نسخة جديدة جاهزة · \(release.build ?? 0)", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Text("اضغط تحديث، ثم أكمل التثبيت في TrollStore. إذا ظهر تطبيق المكبّر، فعّل URL Scheme من إعدادات TrollStore.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { updates.install() } label: {
                    Label(updates.installing ? "جاري فتح TrollStore…" : "تحديث عبر TrollStore", systemImage: "arrow.down.app.fill")
                        .font(.subheadline.bold()).frame(maxWidth: .infinity).padding(12)
                        .background(colors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }.disabled(updates.installing)
            }
            HStack {
                Text("النسخة المثبتة: \(updates.installedBuild)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await updates.check(manual: true) } } label: {
                    if updates.checking { ProgressView() }
                    else { Label("فحص التحديثات", systemImage: "arrow.clockwise") }
                }.font(.caption).disabled(updates.checking)
            }
        }.padding(14).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var appearancePicker: some View {
        let selected = Appearance(rawValue: appearance) ?? .automatic
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("مظهر التطبيق").font(.subheadline.weight(.semibold))
                Spacer()
                Label(selected.title, systemImage: selected.symbol)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("مظهر التطبيق", selection: $appearance) {
                Text("نهاري ☀️").tag(Appearance.light.rawValue)
                Text("ليلي 🌙").tag(Appearance.dark.rawValue)
                Text("تلقائي").tag(Appearance.automatic.rawValue)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearancePicker")
        }.padding(14).background(colors.card, in: RoundedRectangle(cornerRadius: 18))
    }

}

struct RemoteLogo: View {
    let path: String?
    var size: CGFloat = 48
    var body: some View {
        AsyncImage(url: Site.media(path)) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "soccerball").resizable().scaledToFit().foregroundStyle(.secondary.opacity(0.4))
        }.frame(width: size, height: size)
    }
}

struct MatchCard: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(theme: appTheme, dark: colorScheme == .dark) }
    let match: Match
    let checking: Bool
    let action: () -> Void
    @State private var showingInformation = false
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                RemoteLogo(path: match.tournament.logo, size: 20)
                Text(match.providerTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if match.isLive {
                    Label("مباشر", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.bold()).foregroundStyle(colors.accent)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                team(match.home_team)
                VStack(spacing: 6) {
                    if match.hasScore {
                        HStack(spacing: 8) {
                            Text(match.home_team.score.map { String($0) } ?? "—")
                            Text(":")
                            Text(match.away_team.score.map { String($0) } ?? "—")
                        }.font(.title2.bold()).monospacedDigit()
                        Text("الأهداف").font(.caption2).foregroundStyle(.secondary)
                    } else { Text(match.time).font(.title2.bold()).monospacedDigit() }
                    Text(match.state_text ?? "لم تبدأ").font(.caption2).foregroundStyle(.secondary)
                    if match.isLive {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if let clock = match.clockText(now: context.date) {
                                Text("الدقيقة " + clock).font(.caption.bold()).monospacedDigit()
                                    .foregroundStyle(colors.accent)
                            }
                        }
                        if let added = match.added_minutes, added > 0 {
                            Text("+\(added) بدل ضائع").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.frame(width: 112)
                team(match.away_team)
            }
            Label("وقت البداية: " + match.time, systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
            matchInformation
            Button(action: action) {
                HStack(spacing: 8) {
                    if checking { ProgressView().tint(match.playbackURL == nil ? colors.accent : .white) }
                    else { Image(systemName: match.playbackURL == nil ? "clock" : "play.fill") }
                    Text(checking ? "جاري التحقق…" : match.playbackURL == nil ? "البث لم يُنشر بعد" : "شاهد المباراة")
                        .font(.subheadline.bold())
                }.frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(match.playbackURL == nil ? colors.accent : .white)
                    .background(match.playbackURL == nil ? colors.accent.opacity(0.08) : colors.accent, in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).disabled(match.playbackURL == nil).accessibilityIdentifier("watch-\(match.id)")
        }.padding(18).background(colors.card, in: RoundedRectangle(cornerRadius: 22))
    }
    private var matchInformation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tv.fill").foregroundStyle(colors.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("القناة الناقلة").font(.caption).foregroundStyle(.secondary)
                    Text(match.broadcastChannel ?? "القناة الناقلة لم تُعلن بعد")
                        .font(.subheadline.weight(match.broadcastChannel == nil ? .regular : .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.accessibilityElement(children: .combine)
            DisclosureGroup(isExpanded: $showingInformation) {
                VStack(spacing: 12) {
                    informationRow("البطولة", value: match.tournament.name, symbol: "trophy")
                    informationRow("التاريخ", value: MatchInformation.dateTitle(match.date), symbol: "calendar")
                    informationRow("وقت البداية", value: match.time, symbol: "clock")
                    if let round = match.roundTitle {
                        informationRow("الجولة", value: round, symbol: "flag")
                    }
                    if let stadium = match.stadiumName {
                        informationRow("الملعب", value: stadium, symbol: "mappin.and.ellipse")
                    }
                    if let commentator = match.commentatorName {
                        informationRow("المعلق", value: commentator, symbol: "mic")
                    }
                    if match.stadiumName == nil && match.commentatorName == nil {
                        Text("تظهر معلومات الملعب والمعلق عند الإعلان عنها.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 12)
            } label: {
                Label("معلومات المباراة", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
            }.tint(colors.accent)
                .accessibilityIdentifier("match-information-\(match.id)")
        }.padding(12)
            .background(colors.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
    }
    private func informationRow(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }.font(.caption).accessibilityElement(children: .combine)
    }
    private func team(_ team: Team) -> some View {
        VStack(spacing: 9) {
            RemoteLogo(path: team.logo)
            Text(team.name).font(.subheadline.bold()).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }
}

