import SwiftUI
import AVKit
import UIKit

enum FajrStream {
    static let origin = URL(string: "https://tv.alfajertv.com/old/")!
    static func candidates(html: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"src\s*:\s*["'](https://[^\s"'<>]+\.m3u8(?:\?[^\s"'<>]*)?)["']"#) else { return [] }
        var seen = Set<URL>()
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html),
                  let url = URL(string: String(html[range]).replacingOccurrences(of: "&amp;", with: "&")),
                  url.scheme == "https", let host = url.host, url.user == nil, url.password == nil,
                  host.hasSuffix(".hadara.ps") || host.hasSuffix(".alfajertv.com"),
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }
    struct Source {
        let url: URL
        let headers: [String: String]
    }
    static func mediaHeaders(page: URL) -> [String: String] {
        ["Origin": "https://tv.alfajertv.com", "Referer": page.absoluteString]
    }
    static func resolve(page: URL) async throws -> Source {
        guard page.scheme == "https", page.host == origin.host, page.path.hasPrefix("/old/") else {
            throw APIError.server("رابط قناة الفجر غير صالح.")
        }
        // The site issues temporary media URLs. Read a fresh published page on every play.
        let (data, _) = try await PublishedStream.request(page, headers: ["Cache-Control": "no-cache"])
        guard let html = String(data: data, encoding: .utf8) else {
            throw APIError.server("تعذّر قراءة صفحة قناة الفجر.")
        }
        let sources = candidates(html: html)
        guard !sources.isEmpty else { throw APIError.server("لم تنشر هذه الصفحة رابط بث آمنًا قابلًا للتشغيل حاليًا.") }
        let headers = mediaHeaders(page: page)
        var lastError: Error?
        for source in sources {
            try Task.checkCancellation()
            do {
                let (playlist, _) = try await PublishedStream.request(source, headers: headers)
                if String(data: playlist, encoding: .utf8)?.hasPrefix("#EXTM3U") == true { return Source(url: source, headers: headers) }
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw APIError.server("قائمة بث الفجر غير متاحة الآن. جرّب مشغّلًا آخر.")
    }
}

@MainActor
final class FajrPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = true
    @Published var error: String?
    @Published var stage = "تحميل صفحة القناة"
    @Published var details = ""
    @Published var requests = 0
    private var relay: LiveHLSRelay?
    private var observation: NSKeyValueObservation?
    private var timeout: Task<Void, Never>?

    func start(page: URL) async {
        stop(); loading = true; error = nil; details = ""; requests = 0; stage = "تحميل صفحة القناة وقائمة البث"
        do {
            let source = try await FajrStream.resolve(page: page)
            try Task.checkCancellation()
            stage = "اتصال المشغّل داخل التطبيق"
            let relay = LiveHLSRelay(source: source.url, headers: source.headers)
            self.relay = relay
            relay.onFailure = { [weak self] failure in
                Task { @MainActor in
                    guard let self else { return }
                    self.details = (failure as? APIError)?.errorDescription ?? "خطأ تحميل المقاطع: \((failure as NSError).code)"
                }
            }
            let local = try await relay.start()
            let (playlist, _) = try await PublishedStream.request(local)
            guard String(data: playlist, encoding: .utf8)?.hasPrefix("#EXTM3U") == true else {
                throw APIError.server("لم تصل قائمة البث إلى المشغّل.")
            }
            try Task.checkCancellation()
            relay.onRequest = { [weak self] _ in
                Task { @MainActor in self?.requests += 1 }
            }
            stage = "تشغيل الفيديو"
            let item = AVPlayerItem(url: local)
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if item.status == .readyToPlay { self.loading = false; self.timeout?.cancel() }
                    else if item.status == .failed {
                        self.loading = false; self.timeout?.cancel()
                        self.error = "تعذّر تشغيل هذه القناة (\((item.error as NSError?)?.code ?? 0)). جرّب تغيير البث أو مشغّل الموقع."
                        if let event = item.errorLog()?.events.last { self.details += "\nHLS: \(event.errorStatusCode)" }
                    }
                }
            }
            player = AVPlayer(playerItem: item); player?.play()
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                guard let self, self.loading else { return }
                self.loading = false; self.error = "القناة لم تستجب. جرّب مشغّلًا آخر من تغيير البث."
            }
        } catch {
            relay?.stop(); relay = nil
            guard !(error is CancellationError) else { return }
            loading = false
            let code = (error as NSError).code
            self.error = (error as? APIError)?.errorDescription ?? "تعذّر الاتصال ببث الفجر (\(code)). جرّب مشغّلًا آخر أو مشغّل الموقع."
        }
    }
    func stop() {
        timeout?.cancel(); timeout = nil; observation = nil
        relay?.stop(); relay = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    }
}

struct FajrPlayerScreen: View {
    let page: URL
    @StateObject private var model = FajrPlayerModel()
    @State private var retry = UUID()
    var body: some View {
        ZStack {
            VideoPlayer(player: model.player)
            if model.loading {
                Color.black
                VStack(spacing: 12) {
                    ProgressView("جاري تجهيز بث الفجر…")
                    Text(model.stage).font(.caption)
                }.tint(.white).foregroundStyle(.white)
            }
            if let error = model.error {
                Color.black
                VStack(spacing: 20) {
                    Image(systemName: "tv.badge.exclamationmark").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Text("المرحلة: " + model.stage).font(.caption)
                    Text("طلبات المشغّل: \(model.requests)").font(.caption)
                    Text(model.details).font(.caption).multilineTextAlignment(.center)
                    Button("نسخ تفاصيل الخطأ") {
                        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                        UIPasteboard.general.string = "Build \(build)\n\(model.stage)\n\(error)\nRequests: \(model.requests)\n\(model.details)"
                    }
                    Button("إعادة المحاولة") { retry = UUID() }.buttonStyle(.borderedProminent)
                }.foregroundStyle(.white).padding(24)
            }
        }.task(id: retry) { await model.start(page: page) }.onDisappear { model.stop() }
    }
}
