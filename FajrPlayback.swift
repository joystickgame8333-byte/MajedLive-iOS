import SwiftUI
import AVKit

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
    static func resolve(page: URL) async throws -> URL {
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
        var lastError: Error?
        for source in sources {
            try Task.checkCancellation()
            do {
                let (playlist, _) = try await PublishedStream.request(source)
                if String(data: playlist, encoding: .utf8)?.hasPrefix("#EXTM3U") == true { return source }
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
    private var observation: NSKeyValueObservation?
    private var timeout: Task<Void, Never>?

    func start(page: URL) async {
        stop(); loading = true; error = nil
        do {
            let url = try await FajrStream.resolve(page: page)
            try Task.checkCancellation()
            let item = AVPlayerItem(url: url)
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if item.status == .readyToPlay { self.loading = false; self.timeout?.cancel() }
                    else if item.status == .failed {
                        self.loading = false; self.timeout?.cancel()
                        self.error = "تعذّر تشغيل هذه القناة (\((item.error as NSError?)?.code ?? 0)). جرّب تغيير البث أو مشغّل الموقع."
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
            guard !(error is CancellationError) else { return }
            loading = false
            let code = (error as NSError).code
            self.error = (error as? APIError)?.errorDescription ?? "تعذّر الاتصال ببث الفجر (\(code)). جرّب مشغّلًا آخر أو مشغّل الموقع."
        }
    }
    func stop() {
        timeout?.cancel(); timeout = nil; observation = nil
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
                ProgressView("جاري تجهيز بث الفجر…").tint(.white).foregroundStyle(.white)
            }
            if let error = model.error {
                Color.black
                VStack(spacing: 20) {
                    Image(systemName: "tv.badge.exclamationmark").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Button("إعادة المحاولة") { retry = UUID() }.buttonStyle(.borderedProminent)
                }.foregroundStyle(.white).padding(24)
            }
        }.task(id: retry) { await model.start(page: page) }.onDisappear { model.stop() }
    }
}
