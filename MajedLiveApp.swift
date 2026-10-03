import SwiftUI
import WebKit
import UIKit
import AVKit

@main
struct MajedLiveApp: App {
    @AppStorage("appearance") private var appearance = Appearance.automatic.rawValue
    @AppStorage("theme") private var themeName = AppTheme.ruby.rawValue
    private var theme: AppTheme { AppTheme(rawValue: themeName) ?? .ruby }

    var body: some Scene {
        WindowGroup {
            FootballShell()
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.appTheme, theme)
                .tint(theme.accent)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
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

struct Match: Decodable, Identifiable {
    let id: String
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
    let watch_ready: Bool?
    let watch_available: Bool?
    let site_watch_enabled: Bool?
    let watch_url: String?

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
    var hasScore: Bool { isLive || state == "finished" }
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
    let api = MatchesAPI()

    func refresh(offset: Int, clear: Bool = false) async {
        let date = Site.date(offset: offset)
        let id = UUID()
        requestID = id
        if clear || date != displayedDate { matches = []; updated = nil }
        loading = true
        error = nil
        do {
            let result = try await api.load(date: date)
            guard !Task.isCancelled, requestID == id else { return }
            matches = result
            displayedDate = date
            updated = Date()
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            self.error = "لم نتمكن من تحديث الجدول. تحقق من الإنترنت ثم أعد المحاولة."
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
    private let endpoint = URL(string: "https://api.github.com/repos/joystickgame8333-byte/MajedLive-iOS/releases/latest")!
    let installedBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1

    func check(manual: Bool = false) async {
        guard !checking else { return }
        if !manual, let lastCheck, Date().timeIntervalSince(lastCheck) < 120 { return }
        lastCheck = Date()
        checking = true
        defer { checking = false }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MajedLive-iOS", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if manual { notice = "تعذّر التحقق من التحديثات الآن. حاول لاحقًا." }
                return
            }
            let release = try JSONDecoder().decode(AppRelease.self, from: data)
            guard let build = release.build, release.ipa != nil else {
                if manual { notice = "لم تتوفر نسخة صالحة للتحديث بعد." }
                return
            }
            available = build > installedBuild ? release : nil
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

struct MatchesScreen: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(theme: appTheme, dark: colorScheme == .dark) }
    @StateObject private var model = ScheduleModel()
    @StateObject private var updates = AppUpdates()
    @AppStorage("selectedLeague") private var selectedLeague = LeagueFilter.all
    @AppStorage("selectedLeagueTitle") private var selectedLeagueTitle = "كل الدوريات"
    @State private var showingSettings = false
    @State private var day = 0
    @State private var playback: Playback?
    @State private var sourceSelection: BroadcastSelection?
    @State private var pendingPlayback: Playback?
    @State private var checkingMatch: String?
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase

    private var filteredMatches: [Match] { LeagueFilter.matches(model.matches, selected: selectedLeague) }
    private var leagues: [Competition] {
        var seen = Set<String>()
        return model.matches.map(\.tournament).filter { seen.insert($0.filterKey).inserted }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("اختيار اليوم", selection: $day) {
                        Text("اليوم").tag(0)
                        Text("غدًا").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("dayPicker")
                    leaguePicker
                    HStack {
                        Text(day == 0 ? "مباريات اليوم" : "مباريات غدًا")
                            .font(.title2.bold())
                        Spacer()
                        Text("\(filteredMatches.count) مباريات")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        VStack(spacing: 12) {
                            Label(error, systemImage: "wifi.exclamationmark")
                            Button("إعادة المحاولة") { Task { await model.refresh(offset: day) } }
                        }.font(.subheadline).padding().frame(maxWidth: .infinity)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if model.loading && model.matches.isEmpty {
                        ProgressView("جاري تحميل المباريات…")
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else if filteredMatches.isEmpty && model.error == nil {
                        VStack(spacing: 14) {
                            Image(systemName: "sportscourt").font(.largeTitle).foregroundStyle(colors.accent)
                            Text(selectedLeague == LeagueFilter.all ? "لا توجد مباريات لهذا اليوم" : "لا توجد مباريات لهذا الدوري اليوم").font(.headline)
                            Text("اسحب للأسفل لتحديث الجدول").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 55)
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(filteredMatches) { match in
                                MatchCard(match: match, checking: checkingMatch == match.id) {
                                    Task { await open(match) }
                                }.disabled(checkingMatch != nil)
                            }
                        }
                    }
                    if let updated = model.updated {
                        Text("آخر تحديث: \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 12)
                    }
                }.padding(20)
            }
            .background(colors.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                header.padding(.horizontal, 20)
                    .background(colors.card.ignoresSafeArea(edges: .top))
                    .overlay(alignment: .bottom) { Rectangle().fill(colors.accent.opacity(0.12)).frame(height: 1) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if updates.available != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(colors.accent)
                        Text("تحديث جديد متاح").font(.subheadline.weight(.medium))
                        Spacer(minLength: 8)
                        Button { updates.install() } label: {
                            if updates.installing { ProgressView() }
                            else { Text("تحديث").font(.subheadline.bold()) }
                        }.disabled(updates.installing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(colors.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(colors.accent.opacity(0.2), lineWidth: 1))
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(colors.background)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refresh(offset: day) }
            .task(id: "\(day)-\(scenePhase == .active)-\(playback == nil)") {
                guard scenePhase == .active, playback == nil else { return }
                Task { await updates.check() }
                await model.refresh(offset: day)
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    await model.refresh(offset: day)
                    Task { await updates.check() }
                }
            }
            .onChange(of: day) { _ in model.matches = []; model.updated = nil }
            .sheet(isPresented: $showingSettings) { SettingsScreen(updates: updates) }
            .sheet(item: $sourceSelection, onDismiss: {
                playback = pendingPlayback
                pendingPlayback = nil
            }) { selection in
                BroadcastSelectionScreen(selection: selection) { chosen in pendingPlayback = chosen }
            }
            .fullScreenCover(item: $playback) { selected in PlayerScreen(playback: selected) }
            .alert("المشاهدة", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("حسنًا", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .alert("تحديث التطبيق", isPresented: Binding(get: { !showingSettings && updates.notice != nil }, set: { if !$0 { updates.notice = nil } })) {
                Button("حسنًا", role: .cancel) { updates.notice = nil }
            } message: { Text(updates.notice ?? "") }

        }
    }

    private var leaguePicker: some View {
        Menu {
            Button { selectedLeague = LeagueFilter.all; selectedLeagueTitle = "كل الدوريات" } label: {
                if selectedLeague == LeagueFilter.all { Label("إظهار الكل", systemImage: "checkmark") }
                else { Text("إظهار الكل") }
            }
            ForEach(leagues, id: \.filterKey) { league in
                Button { selectedLeague = league.filterKey; selectedLeagueTitle = league.name } label: {
                    if selectedLeague == league.filterKey { Label(league.name, systemImage: "checkmark") }
                    else { Text(league.name) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(colors.accent)
                Text(selectedLeague == LeagueFilter.all ? "كل الدوريات" : selectedLeagueTitle)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Spacer()
                Image(systemName: "chevron.down").font(.caption.bold()).foregroundStyle(.secondary)
            }.padding(14).background(colors.card, in: RoundedRectangle(cornerRadius: 14))
        }.accessibilityLabel("اختيار الدوري")
            .accessibilityIdentifier("leaguePicker")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(colors.accent).frame(width: 40, height: 40)
                Image(systemName: "soccerball").font(.system(size: 23)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(FootballBrand.name).font(.title3.bold())
                Text("المباريات ومصادر البث").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).padding(10)
                    .overlay(alignment: .topTrailing) {
                        if updates.available != nil {
                            Circle().fill(colors.accent).frame(width: 8, height: 8)
                        }
                    }
            }.accessibilityLabel(updates.available == nil ? "الإعدادات" : "الإعدادات، تحديث جديد متاح")
        }.padding(.vertical, 8)
    }

    @MainActor private func open(_ match: Match) async {
        guard checkingMatch == nil else { return }
        checkingMatch = match.id
        defer { checkingMatch = nil }
        do {
            // Recheck availability on every tap; a previously published link can expire.
            let fresh = try await model.api.load(date: match.date)
            guard let current = fresh.first(where: { $0.id == match.id }), current.playbackURL != nil else {
                message = "البث غير متاح لهذه المباراة حاليًا. سيظهر خيار المشاهدة عند توفره."
                await model.refresh(offset: day)
                return
            }
            let sources = try await BroadcastCatalog.sources(for: current)
            guard !sources.isEmpty else { message = "لا توجد مصادر بث متاحة لهذه المباراة حاليًا."; return }
            pendingPlayback = nil
            sourceSelection = BroadcastSelection(title: "\(current.home_team.name) × \(current.away_team.name)", sources: sources)
        } catch {
            message = (error as? APIError)?.errorDescription ?? "تعذّر التحقق من البث. تأكد من الإنترنت وحاول مجددًا."
        }
    }
}

struct SettingsScreen: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(theme: appTheme, dark: colorScheme == .dark) }
    @ObservedObject var updates: AppUpdates
    @AppStorage("appearance") private var appearance = Appearance.automatic.rawValue
    @AppStorage("theme") private var themeName = AppTheme.ruby.rawValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) { appearancePicker; themePicker; updateControls }.padding(20)
            }
            .background(colors.background)
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
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
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                RemoteLogo(path: match.tournament.logo, size: 20)
                Text(match.tournament.name).font(.caption).foregroundStyle(.secondary)
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
            Button(action: action) {
                HStack(spacing: 8) {
                    if checking { ProgressView().tint(match.playbackURL == nil ? colors.accent : .white) }
                    else { Image(systemName: match.playbackURL == nil ? "clock" : "play.fill") }
                    Text(checking ? "جاري التحقق…" : match.playbackURL == nil ? "البث لم يُنشر بعد" : "شاهد المباراة")
                        .font(.subheadline.bold())
                }.frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(match.playbackURL == nil ? colors.accent : .white)
                    .background(match.playbackURL == nil ? colors.accent.opacity(0.08) : colors.accent, in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).accessibilityIdentifier("watch-\(match.id)")
        }.padding(18).background(colors.card, in: RoundedRectangle(cornerRadius: 22))
    }
    private func team(_ team: Team) -> some View {
        VStack(spacing: 9) {
            RemoteLogo(path: team.logo)
            Text(team.name).font(.subheadline.bold()).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }
}

@MainActor
final class PlayerState: ObservableObject {
    @Published var loading = true
    @Published var error: String?
    weak var webView: WKWebView?
    func retry() {
        error = nil
        loading = true
        webView?.reload()
    }
}

struct PlayerScreen: View {
    let playback: Playback
    @StateObject private var state = PlayerState()
    @State private var selectedID: String?
    init(playback: Playback) {
        self.playback = playback
        _selectedID = State(initialValue: playback.initialServerID)
    }
    @State private var preferNativeHLS = true
    @State private var originalPlayback = true
    @State private var reloadID = UUID()
    private var selected: StreamServer {
        playback.servers.first(where: { $0.id == selectedID })
            ?? playback.servers.first(where: { $0.is_default == true })
            ?? playback.servers[0]
    }
    private var supportsOriginalPlayer: Bool {
        selected.playbackURL?.host == "player.majed-koora.live" && !selected.nativeVideo
    }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").padding(12) }
                    .accessibilityLabel("إغلاق المشغّل")
                Text(playback.title).font(.subheadline.bold()).lineLimit(1)
                Spacer(minLength: 0)
                Button { if selected.nativeVideo || (supportsOriginalPlayer && originalPlayback) { reloadID = UUID() } else { state.retry() } } label: { Image(systemName: "arrow.clockwise").padding(12) }
                    .accessibilityLabel("تحديث المشغّل")
            }.foregroundStyle(.white).background(Color.black)
            if supportsOriginalPlayer {
                HStack {
                    Text(originalPlayback ? "مشغّل آيفون الأصلي · حتى 720p" : "مشغّل الموقع")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button(originalPlayback ? "مشغّل الموقع" : "تشغيل آيفون") {
                        state.error = nil; state.loading = true
                        originalPlayback.toggle()
                    }.font(.caption.bold())
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if !selected.nativeVideo && (!supportsOriginalPlayer || !originalPlayback) {
                HStack(spacing: 8) {
                    Text(preferNativeHLS ? "تشغيل متوافق مع آيفون" : "محرك الموقع")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button(preferNativeHLS ? "تجربة محرك الموقع" : "تشغيل آيفون") {
                        state.error = nil
                        state.loading = true
                        preferNativeHLS.toggle()
                    }.font(.caption.bold())
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            HStack {
                Label(playback.providerName, systemImage: "play.tv.fill")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Menu {
                    ForEach(playback.servers) { server in
                        Button { selectedID = server.id } label: {
                            if selected.id == server.id { Label(server.name, systemImage: "checkmark") }
                            else { Text(server.name) }
                        }
                    }
                } label: {
                    Label("تغيير البث", systemImage: "arrow.triangle.2.circlepath").font(.caption.bold())
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
            ZStack {
                if let url = selected.playbackURL {
                    if selected.nativeVideo { NativeVideoPlayer(url: url).id("\(selected.id)-\(reloadID)") }
                    else if supportsOriginalPlayer && originalPlayback {
                        OriginalPlayerScreen(server: url, watch: playback.url).id("\(selected.id)-\(reloadID)")
                    }
                    else { PlayerWebView(url: url, referrer: playback.url, preferNativeHLS: preferNativeHLS, state: state).id("\(selected.id)-\(preferNativeHLS)") }
                }
                if !selected.nativeVideo && !(supportsOriginalPlayer && originalPlayback) && state.loading && state.error == nil {
                    Color.black
                    ProgressView("جاري تشغيل البث…").tint(.white).foregroundStyle(.white)
                }
                if let error = state.error {
                    Color.black
                    VStack(spacing: 20) {
                        Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center)
                        Button("إعادة المحاولة") { state.retry() }.buttonStyle(.borderedProminent)
                    }.foregroundStyle(.white).padding(30)
                }
            }
        }.background(Color.black).statusBarHidden()
            .onChange(of: selectedID) { _ in state.error = nil; state.loading = true }
    }
}

struct NativeVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player = AVPlayer(url: url); player?.play() }
            .onDisappear { player?.pause(); player = nil }
    }
}

struct PlayerWebView: UIViewRepresentable {
    let url: URL
    let referrer: URL
    let preferNativeHLS: Bool
    let state: PlayerState
    func makeCoordinator() -> Coordinator { Coordinator(url: url, state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        if preferNativeHLS {
            // Prefer Apple's supported HLS path in the published player's adapter.
            // This changes only media engine selection, not URLs, access or DRM.
            let nativeHLS = """
            (function () {
                if (location.hostname !== 'player.majed-koora.live') return;
                var appleMobile = /iPhone|iPad|iPod/.test(navigator.userAgent) ||
                    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
                var probe = document.createElement('video');
                if (!appleMobile || !(probe.canPlayType('application/vnd.apple.mpegurl') ||
                    probe.canPlayType('application/x-mpegurl'))) return;
                var library;
                function preferNative(value) {
                    if (value && typeof value.isSupported === 'function') {
                        value.isSupported = function () { return false; };
                    }
                    return value;
                }
                var descriptor = Object.getOwnPropertyDescriptor(window, 'Hls');
                if (descriptor && !descriptor.configurable) return;
                library = preferNative(window.Hls);
                Object.defineProperty(window, 'Hls', {
                    configurable: true,
                    get: function () { return library; },
                    set: function (value) { library = preferNative(value); }
                });
            })();
            """
            configuration.userContentController.addUserScript(WKUserScript(
                source: nativeHLS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        state.webView = view
        // Embed the published server alone, using its original watch page as the base.
        let escaped = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        view.scrollView.isScrollEnabled = false
        view.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:#000}iframe{width:100%;height:100%;border:0}</style>
        </head><body><iframe src="\(escaped)" allow="autoplay; encrypted-media; fullscreen; picture-in-picture" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """, baseURL: referrer)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let url: URL
        let state: PlayerState
        init(url: URL, state: PlayerState) { self.url = url; self.state = state }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.loading = true
            state.error = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.loading = false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
                state.loading = false
                state.error = "سيرفر البث رفض التشغيل (\(response.statusCode)). يحتاج صاحب الموقع السماح للمشغّل بالعمل داخل التطبيق."
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               navigationAction.request.url?.host != url.host {
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        private func failed(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            state.loading = false
            state.error = "تعذّر فتح مشغّل الموقع. جرّب تحديثه أو أعد المحاولة عندما يكون البث متاحًا."
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.loading = false
            state.error = "توقف المشغّل. اضغط إعادة المحاولة."
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            return nil
        }
    }
}
