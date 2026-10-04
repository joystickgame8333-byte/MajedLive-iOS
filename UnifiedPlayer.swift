import SwiftUI
import AVKit

struct StreamQuality: Identifiable, Equatable {
    let id: Int
    let label: String
}

enum HLSQuality {
    struct Variant { let attributes: String; let uri: String; let height: Int }
    static func variants(_ playlist: String) -> [Variant] {
        let lines = playlist.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return lines.indices.compactMap { index in
            guard lines[index].hasPrefix("#EXT-X-STREAM-INF:"), index + 1 < lines.count,
                  !lines[index + 1].isEmpty, !lines[index + 1].hasPrefix("#") else { return nil }
            let height = NTVProvider.captured(#"RESOLUTION=\d+x(\d+)"#, in: lines[index]).first?.first.flatMap(Int.init) ?? 0
            return Variant(attributes: lines[index], uri: lines[index + 1], height: height)
        }
    }
    static func choices(_ playlist: String) -> [StreamQuality] {
        let heights = Set(variants(playlist).map(\.height).filter { $0 > 0 }).sorted(by: >)
        return [StreamQuality(id: 0, label: heights.isEmpty ? "جودة المصدر" : "تلقائي")] + heights.map { StreamQuality(id: $0, label: "\($0)p") }
    }
    static func master(_ playlist: String, height: Int) -> String {
        // Keep media groups (including separate audio). Remove only dangling VIDEO references.
        let lines = playlist.components(separatedBy: .newlines)
        let videoGroups = Set(lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") && $0.contains("TYPE=VIDEO") }
            .compactMap { NTVProvider.captured(#"GROUP-ID="([^"]+)""#, in: $0).first?.first })
        let available = Set(variants(playlist).map(\.height))
        let selected = available.contains(height) && height > 0 ? height : 0
        var output: [String] = []; var index = 0
        while index < lines.count {
            var line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:"), index + 1 < lines.count {
                let variantHeight = NTVProvider.captured(#"RESOLUTION=\d+x(\d+)"#, in: line).first?.first.flatMap(Int.init) ?? 0
                if selected > 0 && variantHeight != selected { index += 2; continue }
                if let group = NTVProvider.captured(#"VIDEO="([^"]+)""#, in: line).first?.first, !videoGroups.contains(group) {
                    line = line.replacingOccurrences(of: #",?VIDEO="[^"]+""#, with: "", options: .regularExpression)
                }
            }
            output.append(line); index += 1
        }
        return output.joined(separator: "\n")
    }
}

@MainActor
final class UnifiedPlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var embedded: URL?
    @Published private(set) var embeddedReferrer: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var qualities: [StreamQuality] = []
    @Published private(set) var selectedQuality = 0
    private var source: URL?
    private var headers: [String: String] = [:]
    private var playlist = ""
    private var relay: LiveHLSRelay?
    private var observation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var timeout: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var generation = UUID()

    func load(server: StreamServer, watch: URL) async {
        stop(); let run = generation
        loading = true; error = nil; qualities = []; embedded = nil; selectedQuality = 0
        do {
            guard let url = server.playbackURL else { throw APIError.server("رابط البث غير متاح.") }
            let media: URL
            if server.type == "ntv_page" {
                let resolved = try await NTVProvider.source(page: url, includeAlternatives: false)
                try Task.checkCancellation()
                guard generation == run else { return }
                guard let frame = resolved.servers.first?.playbackURL else { throw APIError.server("هذا البث غير متاح الآن.") }
                embeddedReferrer = url; embedded = frame; loading = false; return
            } else if server.type == "fajr_hls_page" {
                let resolved = try await FajrStream.resolve(page: url)
                guard generation == run else { return }
                media = resolved.url; headers = resolved.headers
            } else if url.host == "player.majed-koora.live" {
                media = try await PublishedStream.resolve(player: url, watch: watch)
                guard generation == run else { return }
                headers = ["Origin": "https://player.majed-koora.live"]
            } else if server.nativeVideo {
                media = url; headers = [:]
            } else {
                embeddedReferrer = watch; embedded = url; loading = false; return
            }
            try Task.checkCancellation()
            guard generation == run else { return }
            source = media
            if server.type == "mp4" || media.pathExtension.lowercased() == "mp4" {
                attach(AVPlayerItem(url: media), run: run)
                qualities = [StreamQuality(id: 0, label: "جودة المصدر")]
                return
            }
            let (data, _) = try await PublishedStream.request(media, headers: headers)
            try Task.checkCancellation()
            guard generation == run else { return }
            guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
                throw APIError.server("المصدر لم يرسل قائمة بث صالحة.")
            }
            playlist = text; qualities = HLSQuality.choices(text)
            try await prepare(height: 0, run: run)
        } catch {
            guard generation == run, !Task.isCancelled else { return }
            fail(error)
        }
    }

    func selectQuality(_ quality: StreamQuality) {
        guard qualities.contains(quality), quality.id != selectedQuality else { return }
        selectedQuality = quality.id
        qualityTask?.cancel()
        generation = UUID(); let run = generation
        qualityTask = Task {
            do { try await prepare(height: quality.id, run: run) }
            catch { if generation == run && !Task.isCancelled { fail(error) } }
        }
    }
    private func prepare(height: Int, run: UUID) async throws {
        guard let source else { return }
        releasePlayer(); loading = true; error = nil
        let root = HLSQuality.master(playlist, height: height)
        let relay = LiveHLSRelay(source: source, headers: headers, rootPlaylist: root)
        self.relay = relay
        let local = try await relay.start()
        try Task.checkCancellation()
        guard generation == run else { relay.stop(); return }
        attach(AVPlayerItem(url: local), run: run)
    }
    private func attach(_ item: AVPlayerItem, run: UUID) {
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                if item.status == .readyToPlay { self.loading = false; self.timeout?.cancel() }
                if item.status == .failed {
                    self.loading = false; self.timeout?.cancel()
                    self.error = "تعذّر تشغيل هذا البث (\((item.error as NSError?)?.code ?? 0)). جرّب مصدرًا آخر أو أعد المحاولة."
                }
            }
        }
        let current = AVPlayer(playerItem: item)
        current.isMuted = isMuted
        playbackObservation = current.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.isPlaying = player.timeControlStatus == .playing
            }
        }
        player = current; current.play()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            guard let self, self.generation == run, self.loading else { return }
            self.player?.pause()
            self.loading = false; self.error = "البث لم يستجب. جرّب مصدرًا آخر."
        }
    }
    private func fail(_ failure: Error) {
        releasePlayer(); loading = false
        error = (failure as? APIError)?.errorDescription ?? "تعذّر تحميل البث. تحقق من الاتصال ثم أعد المحاولة."
    }
    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }
    func toggleMute() { isMuted.toggle(); player?.isMuted = isMuted }
    private func releasePlayer() {
        timeout?.cancel(); timeout = nil; observation = nil; playbackObservation = nil; isPlaying = false
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        relay?.stop(); relay = nil
    }
    func stop() {
        generation = UUID(); qualityTask?.cancel(); qualityTask = nil
        releasePlayer(); source = nil; playlist = ""; headers = [:]; embeddedReferrer = nil
    }
}

