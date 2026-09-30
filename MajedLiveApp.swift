import SwiftUI
import WebKit
import UIKit

@main
struct MajedLiveApp: App {
    @AppStorage("appearance") private var appearance = Appearance.automatic.rawValue

    var body: some Scene {
        WindowGroup {
            MatchesScreen()
                .environment(\.layoutDirection, .rightToLeft)
                .tint(Palette.red)
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

enum Palette {
    static let red = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.40, blue: 0.52, alpha: 1)
            : UIColor(red: 0.65, green: 0.06, blue: 0.18, alpha: 1)
    })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
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
    let name: String
    let logo: String?
}

struct Match: Decodable, Identifiable {
    let id: String
    let date: String
    let time: String
    let state: String
    let state_text: String?
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
    @AppStorage("appearance") private var appearance = Appearance.automatic.rawValue
    @StateObject private var model = ScheduleModel()
    @StateObject private var updates = AppUpdates()
    @State private var day = 0
    @State private var playback: Playback?
    @State private var checkingMatch: String?
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    appearancePicker
                    updateControls
                    Picker("اختيار اليوم", selection: $day) {
                        Text("اليوم").tag(0)
                        Text("غدًا").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("dayPicker")
                    HStack {
                        Text(day == 0 ? "مباريات اليوم" : "مباريات غدًا")
                            .font(.title2.bold())
                        Spacer()
                        Text("\(model.matches.count) مباريات")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        VStack(spacing: 12) {
                            Label(error, systemImage: "wifi.exclamationmark")
                            Button("إعادة المحاولة") { Task { await model.refresh(offset: day) } }
                        }.font(.subheadline).padding().frame(maxWidth: .infinity)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if model.loading && model.matches.isEmpty {
                        ProgressView("جاري تحميل المباريات…")
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else if model.matches.isEmpty && model.error == nil {
                        VStack(spacing: 14) {
                            Image(systemName: "sportscourt").font(.largeTitle).foregroundStyle(Palette.red)
                            Text("لا توجد مباريات لهذا اليوم").font(.headline)
                            Text("اسحب للأسفل لتحديث الجدول").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 55)
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(model.matches) { match in
                                MatchCard(match: match, checking: checkingMatch == match.id) {
                                    Task { await open(match) }
                                }.disabled(checkingMatch != nil)
                            }
                        }
                    }
                    VStack(spacing: 6) {
                        Text("مواعيد المباريات بتوقيت الرياض")
                        if let updated = model.updated {
                            Text("آخر تحديث: \(updated.formatted(date: .omitted, time: .shortened))")
                        }
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 12)
                }.padding(20)
            }
            .background(Palette.background)
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
            .fullScreenCover(item: $playback) { selected in PlayerScreen(playback: selected) }
            .alert("المشاهدة", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("حسنًا", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .alert("تحديث التطبيق", isPresented: Binding(get: { updates.notice != nil }, set: { if !$0 { updates.notice = nil } })) {
                Button("حسنًا", role: .cancel) { updates.notice = nil }
            } message: { Text(updates.notice ?? "") }
        }
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
                        .background(Palette.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
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
        }.padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
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
        }.padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Palette.red).frame(width: 56, height: 56)
                Image(systemName: "soccerball").font(.system(size: 30)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("ماجد لايف").font(.title.bold())
                Text("كل مباراة… في مكان واحد").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("تجريبي").font(.caption2.bold()).foregroundStyle(Palette.red)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Palette.red.opacity(0.09), in: Capsule())
        }.padding(.vertical, 8)
    }

    @MainActor private func open(_ match: Match) async {
        guard checkingMatch == nil else { return }
        checkingMatch = match.id
        defer { checkingMatch = nil }
        do {
            // Recheck availability on every tap; a previously published link can expire.
            let fresh = try await model.api.load(date: match.date)
            guard let current = fresh.first(where: { $0.id == match.id }), let url = current.playbackURL else {
                message = "البث لم يُنشر في الموقع بعد. عندما يفعّله صاحب الموقع سيظهر زر المشاهدة تلقائيًا."
                await model.refresh(offset: day)
                return
            }
            playback = Playback(title: "\(current.home_team.name) × \(current.away_team.name)", url: url)
        } catch {
            message = "تعذّر التحقق من البث. تأكد من الإنترنت وحاول مجددًا."
        }
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
                        .font(.caption2.bold()).foregroundStyle(Palette.red)
                }
            }
            HStack(alignment: .center, spacing: 8) {
                team(match.home_team)
                VStack(spacing: 6) {
                    if match.hasScore {
                        Text("\(match.home_team.score ?? 0) : \(match.away_team.score ?? 0)")
                            .font(.title2.bold()).monospacedDigit().environment(\.layoutDirection, .leftToRight)
                    } else { Text(match.time).font(.title2.bold()).monospacedDigit() }
                    Text(match.state_text ?? "لم تبدأ").font(.caption2).foregroundStyle(.secondary)
                }.frame(width: 100)
                team(match.away_team)
            }
            Button(action: action) {
                HStack(spacing: 8) {
                    if checking { ProgressView().tint(match.playbackURL == nil ? Palette.red : .white) }
                    else { Image(systemName: match.playbackURL == nil ? "clock" : "play.fill") }
                    Text(checking ? "جاري التحقق…" : match.playbackURL == nil ? "البث لم يُنشر بعد" : "مشاهدة البث")
                        .font(.subheadline.bold())
                }.frame(maxWidth: .infinity).padding(.vertical, 13)
                    .foregroundStyle(match.playbackURL == nil ? Palette.red : .white)
                    .background(match.playbackURL == nil ? Palette.red.opacity(0.08) : Palette.red, in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).accessibilityIdentifier("watch-\(match.id)")
        }.padding(18).background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").padding(12) }
                    .accessibilityLabel("إغلاق المشغّل")
                Text(playback.title).font(.subheadline.bold()).lineLimit(1)
                Spacer(minLength: 0)
                Button { state.retry() } label: { Image(systemName: "arrow.clockwise").padding(12) }
                    .accessibilityLabel("تحديث المشغّل")
            }.foregroundStyle(.white).background(Color.black)
            ZStack {
                PlayerWebView(url: playback.url, state: state)
                if state.loading && state.error == nil {
                    Color.black
                    ProgressView("جاري فتح مشغّل الموقع…").tint(.white).foregroundStyle(.white)
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
    }
}

struct PlayerWebView: UIViewRepresentable {
    let url: URL
    let state: PlayerState
    func makeCoordinator() -> Coordinator { Coordinator(url: url, state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        state.webView = view
        // Establish the normal website origin/cookies before following its published link.
        view.load(URLRequest(url: Site.origin))
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
        var followedPublishedLink = false
        init(url: URL, state: PlayerState) { self.url = url; self.state = state }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.loading = true
            state.error = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !followedPublishedLink {
                guard webView.url?.host == Site.origin.host else {
                    state.loading = false
                    return
                }
                followedPublishedLink = true
                // Same navigation as the website's openMatch(), preserving the website referrer.
                guard let encoded = try? JSONEncoder().encode(url.absoluteString),
                      let target = String(data: encoded, encoding: .utf8) else {
                    state.loading = false
                    state.error = "تعذّر قراءة رابط المشغّل."
                    return
                }
                webView.evaluateJavaScript("window.location.assign(\(target));", completionHandler: nil)
            } else {
                state.loading = false
            }
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
            // Keep user-opened player/server links inside the app. Ignore automatic popup windows.
            if navigationAction.targetFrame == nil && navigationAction.navigationType == .linkActivated,
               navigationAction.request.url?.scheme == "https" {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
