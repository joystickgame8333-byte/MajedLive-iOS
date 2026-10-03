import SwiftUI
import AVKit
import UIKit
import CryptoKit
import Network

// Uses the same short-lived authorization and response format as the published player.
// No URLs, authorization values, DRM keys or media bytes are saved to disk.
enum PublishedStream {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
    struct Envelope: Decodable { let v: Int; let alg: String; let iv: String; let tag: String; let data: String }
    struct Source: Decodable {
        struct DRM: Decodable { let enabled: Bool? }
        let url: URL
        let format: String?
        let drm: DRM?
    }
    static func base64(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }
    static func request(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.server("تعذّر تحميل البث من السيرفر (\(code)).")
        }
        return (data, response)
    }
    static func resolve(player: URL, watch: URL) async throws -> URL {
        let available = try await WatchAPI().servers(publishedURL: watch)
        guard available.contains(where: { $0.playbackURL == player }) else {
            throw APIError.server("هذا السيرفر لم يعد منشورًا للمباراة.")
        }
        guard player.host == "player.majed-koora.live", player.scheme == "https",
              let channel = URLComponents(url: player, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "channel" || $0.name == "id" })?.value else {
            throw APIError.server("هذا السيرفر لا يتيح التشغيل الأصلي حاليًا.")
        }
        let (page, _) = try await request(player, headers: ["Referer": watch.absoluteString])
        guard let html = String(data: page, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "name=\"majed-player-authorization\"\\s+content=\"([^\"]+)\""),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else {
            throw APIError.server("لم يصدر الموقع تصريح تشغيل صالحًا.")
        }
        let authorization = String(html[range])
        var endpoint = URLComponents(string: "https://player.majed-koora.live/api/stream.php")!
        endpoint.queryItems = [URLQueryItem(name: "id", value: channel)]
        let (payload, _) = try await request(endpoint.url!, headers: ["Accept": "application/json",
            "Referer": player.absoluteString, "X-Player-Authorization": authorization])
        let envelope = try JSONDecoder().decode(Envelope.self, from: payload)
        guard envelope.v == 1, envelope.alg == "A256GCM", let iv = base64(envelope.iv),
              let tag = base64(envelope.tag), let ciphertext = base64(envelope.data) else {
            throw APIError.server("صيغة استجابة المشغّل غير معروفة.")
        }
        let context = Data("majed-player-stream-v1".utf8)
        let key = SymmetricKey(data: SHA256.hash(data: Data("majed-player-stream-v1|\(authorization)".utf8)))
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        let decoded = try AES.GCM.open(box, using: key, authenticating: context)
        let source = try JSONDecoder().decode(Source.self, from: decoded)
        guard source.drm?.enabled != true else { throw APIError.server("هذا المصدر يحتاج نظام ترخيص المشغّل الأصلي.") }
        guard source.url.scheme == "https", source.url.host != nil, source.url.user == nil,
              source.url.password == nil, source.format == "hls" else {
            throw APIError.server("المصدر لا يقدّم رابط HLS صالحًا.")
        }
        return source.url
    }
}

enum HLSPlaylist {
    // Select the published 720p rendition directly, avoiding malformed master VIDEO groups.
    static func byteRange(_ header: String, count: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), count > 0 else { return nil }
        let values = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard values.count == 2 else { return nil }
        if values[0].isEmpty {
            guard let suffix = Int(values[1]), suffix > 0 else { return nil }
            return max(0, count - suffix)..<count
        }
        guard let start = Int(values[0]), start >= 0, start < count else { return nil }
        let end: Int
        if values[1].isEmpty { end = count - 1 }
        else { guard let value = Int(values[1]), value >= start else { return nil }; end = min(value, count - 1) }
        return start..<(end + 1)
    }
    static func compatibleVariant(_ text: String, base: URL) -> URL {
        let lines = text.components(separatedBy: .newlines)
        var candidates: [(Int, URL)] = []
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
            guard index + 1 < lines.count,
                  let url = URL(string: lines[index + 1].trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
                  url.scheme == "https" else { continue }
            let height: Int
            if let regex = try? NSRegularExpression(pattern: "RESOLUTION=[0-9]+x([0-9]+)"),
               let match = regex.firstMatch(in: lines[index], range: NSRange(lines[index].startIndex..., in: lines[index])),
               let range = Range(match.range(at: 1), in: lines[index]) {
                height = Int(lines[index][range]) ?? 0
            } else { height = 0 }
            candidates.append((height, url))
        }
        return candidates.filter { $0.0 > 0 && $0.0 <= 720 }.max(by: { $0.0 < $1.0 })?.1
            ?? candidates.min(by: { $0.0 < $1.0 })?.1 ?? base
    }
    static func rewrite(_ text: String, base: URL, map: (URL) -> URL) -> String {
        text.components(separatedBy: .newlines).map { line in
            if line.hasPrefix("#") {
                guard let regex = try? NSRegularExpression(pattern: "URI=\"([^\"]+)\"") else { return line }
                var result = line
                for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    guard let value = Range(match.range(at: 1), in: line),
                          let url = URL(string: String(line[value]), relativeTo: base)?.absoluteURL,
                          let target = Range(match.range(at: 1), in: result) else { continue }
                    result.replaceSubrange(target, with: map(url).absoluteString)
                }
                return result
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return line }
            return map(url).absoluteString
        }.joined(separator: "\n")
    }
}

// A per-playback loopback adapter forwards the site's authorized HTTPS media requests.
// This preserves Origin for native HLS subrequests and serves correct media MIME types.
final class LiveHLSRelay {
    private let queue = DispatchQueue(label: "MajedLive.HLSRelay")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let secret = UUID().uuidString
    private let source: URL
    private let upstreamHeaders: [String: String]
    private var port: UInt16 = 0
    var onFailure: ((Error) -> Void)?
    var onRequest: ((String) -> Void)?
    init(source: URL, headers: [String: String] = ["Origin": "https://player.majed-koora.live"]) {
        self.source = source
        self.upstreamHeaders = headers
    }
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !completed else { return }
                switch state {
                case .ready:
                    completed = true
                    self.port = listener.port!.rawValue
                    continuation.resume(returning: self.localURL(self.source))
                case .failed(let error): completed = true; continuation.resume(throwing: error)
                case .cancelled: completed = true; continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            connections.forEach { $0.cancel() }; connections.removeAll()
        }
    }
    private func localURL(_ remote: URL) -> URL {
        let encoded = Data(remote.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let name = ["css", "m3u8"].contains(remote.pathExtension.lowercased()) ? "playlist.m3u8" : "segment.ts"
        return URL(string: "http://localhost:\(port)/\(secret)/\(encoded)/\(name)")!
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = buffered; if let data { bytes.append(data) }
            guard bytes.count <= 16384 else { connection.cancel(); return }
            if let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") {
                Task { await self.serve(connection, request: text) }
            } else if done { connection.cancel() }
            else { self.receive(connection, buffered: bytes) }
        }
    }
    private func serve(_ connection: NWConnection, request: String) async {
        let first = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard first.count >= 2, first[0] == "GET" || first[0] == "HEAD" else { connection.cancel(); return }
        let parts = first[1].split(separator: "/")
        guard parts.count == 3, parts[0] == Substring(secret),
              let bytes = PublishedStream.base64(String(parts[1])), let value = String(data: bytes, encoding: .utf8),
              let remote = URL(string: value), remote.scheme == "https", remote.host == source.host,
              remote.user == nil, remote.password == nil else { connection.cancel(); return }
        onRequest?(["css", "m3u8"].contains(remote.pathExtension.lowercased()) ? "قائمة البث" : "مقطع الفيديو")
        do {
            // All URLs retain the original site's signatures; no authentication is replaced.
            let (data, response) = try await PublishedStream.request(remote, headers: upstreamHeaders)
            var body = data
            var mime = response.mimeType ?? "application/octet-stream"
            if let playlist = String(data: data, encoding: .utf8), playlist.hasPrefix("#EXTM3U") {
                body = Data(HLSPlaylist.rewrite(playlist, base: remote, map: localURL).utf8)
                mime = "application/vnd.apple.mpegurl"
            } else if data.first == 0x47 { mime = "video/mp2t" }
            let total = body.count
            let rangeHeader = request.components(separatedBy: "\r\n").first {
                $0.lowercased().hasPrefix("range:")
            }?.dropFirst(6).trimmingCharacters(in: .whitespaces)
            var status = "200 OK"
            var extra = "Accept-Ranges: bytes\r\n"
            if let rangeHeader {
                if let range = HLSPlaylist.byteRange(rangeHeader, count: total) {
                    body = body.subdata(in: range)
                    status = "206 Partial Content"
                    extra += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)\r\n"
                } else {
                    body = Data(); status = "416 Range Not Satisfiable"
                    extra += "Content-Range: bytes */\(total)\r\n"
                }
            }
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\n\(extra)Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            var result = Data(header.utf8)
            if first[0] != "HEAD" { result.append(body) }
            finish(connection, response: result)
        } catch {
            onFailure?(error)
            finish(connection, response: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        }
    }
    private func finish(_ connection: NWConnection, response: Data) {
        // A final TCP context sends FIN after the response bytes. Do not cancel the
        // connection as soon as Network.framework has merely processed the send.
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let self else { connection.cancel(); return }
            if let error { self.onFailure?(error); self.release(connection); return }
            self.drain(connection)
            self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.connections.contains(where: { $0 === connection }) else { return }
                self.release(connection)
            }
        })
    }
    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, done, error in
            guard let self else { connection.cancel(); return }
            if done || error != nil { self.release(connection) }
            else { self.drain(connection) }
        }
    }
    private func release(_ connection: NWConnection) {
        queue.async { [weak self] in
            connection.cancel()
            self?.connections.removeAll { $0 === connection }
        }
    }

}

@MainActor
final class OriginalPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var loading = true
    @Published var error: String?
    @Published var stage = "تصريح الموقع"
    @Published var details = ""
    @Published var mediaRequests = 0
    @Published var lastRequest = "لم يطلب المشغّل بيانات بعد"
    private var readinessTimeout: Task<Void, Never>?
    private static func errorCode(_ error: Error) -> String {
        var result: [String] = []
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let value = current else { break }
            // Never expose signed source URLs or authorization from error userInfo.
            let domain = value.domain.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil ? value.domain : "MediaError"
            result.append("\(domain): \(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result.joined(separator: " → ")
    }
    private var relay: LiveHLSRelay?
    private var observation: NSKeyValueObservation?
    func start(server: URL, watch: URL) async {
        stop(); loading = true; error = nil; stage = "تصريح الموقع"; details = ""; mediaRequests = 0; lastRequest = "لم يطلب المشغّل بيانات بعد"
        do {
            let master = try await PublishedStream.resolve(player: server, watch: watch)
            stage = "قائمة البث"
            let (data, _) = try await PublishedStream.request(master, headers: ["Origin": "https://player.majed-koora.live"])
            guard let playlist = String(data: data, encoding: .utf8), playlist.hasPrefix("#EXTM3U") else {
                throw APIError.server("السيرفر لم يرسل قائمة بث صالحة.")
            }
            let selected = HLSPlaylist.compatibleVariant(playlist, base: master)
            let relay = LiveHLSRelay(source: selected)
            self.relay = relay
            relay.onFailure = { [weak self] failure in
                Task { @MainActor in
                    guard let self else { return }
                    self.details = "تحميل مقاطع البث: " + ((failure as? APIError)?.errorDescription ?? Self.errorCode(failure))
                }
            }
            stage = "اتصال المشغّل داخل التطبيق"
            let local = try await relay.start()
            // Test the same loopback playlist AVPlayer will request before starting it.
            let (localData, _) = try await PublishedStream.request(local)
            guard String(data: localData, encoding: .utf8)?.hasPrefix("#EXTM3U") == true else {
                throw APIError.server("لم تصل قائمة البث إلى المشغّل داخل التطبيق.")
            }
            try Task.checkCancellation()
            relay.onRequest = { [weak self] resource in
                Task { @MainActor in
                    guard let self else { return }
                    self.mediaRequests += 1; self.lastRequest = resource
                }
            }
            stage = "تشغيل الفيديو"
            let item = AVPlayerItem(url: local)
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if item.status == .readyToPlay { self.loading = false; self.readinessTimeout?.cancel() }
                    if item.status == .failed {
                        self.loading = false
                        self.readinessTimeout?.cancel()
                        self.error = "تعذّر تشغيل الفيديو بمشغّل آيفون."
                        if let failure = item.error { self.details = Self.errorCode(failure) + "\n" + self.details }
                        if let event = item.errorLog()?.events.last {
                            self.details += "\nHLS: \(event.errorStatusCode)"
                        }
                    }
                }
            }
            let player = AVPlayer(playerItem: item)
            self.player = player
            player.play()
            readinessTimeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                guard let self, self.loading else { return }
                self.loading = false
                self.error = "انتهت مهلة تجهيز الفيديو."
                if let event = item.errorLog()?.events.last { self.details += "\nHLS: \(event.errorStatusCode)" }
            }
        } catch {
            relay?.stop(); relay = nil
            loading = false
            if !(error is CancellationError) {
                self.error = (error as? APIError)?.errorDescription ?? "تعذّر تجهيز البث. أعد المحاولة."
                details = Self.errorCode(error) + (details.isEmpty ? "" : "\n" + details)
            }
        }
    }
    func stop() {
        readinessTimeout?.cancel(); readinessTimeout = nil
        observation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        relay?.stop(); relay = nil
    }
}

struct OriginalPlayerScreen: View {
    let server: URL
    let watch: URL
    @StateObject private var model = OriginalPlayerModel()
    @State private var retryID = UUID()
    var body: some View {
        ZStack {
            VideoPlayer(player: model.player)
            if model.loading {
                VStack(spacing: 12) {
                    ProgressView("جاري تجهيز تشغيل آيفون…")
                    Text(model.stage).font(.caption)
                }.tint(.white).foregroundStyle(.white)
            }
            if let error = model.error {
                Color.black
                VStack(spacing: 18) {
                    Text(error).multilineTextAlignment(.center)
                    Text("المرحلة: " + model.stage).font(.caption)
                    Text("طلبات المشغّل: \(model.mediaRequests) · \(model.lastRequest)").font(.caption)
                    Text(model.details).font(.caption.monospaced()).multilineTextAlignment(.center)
                        .environment(\.layoutDirection, .leftToRight)
                    Button("نسخ تفاصيل الخطأ") {
                        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                        UIPasteboard.general.string = "Build \(build)\n\(model.stage)\n\(error)\nRequests: \(model.mediaRequests) · \(model.lastRequest)\n\(model.details)"
                    }
                    Button("إعادة المحاولة") { retryID = UUID() }.buttonStyle(.borderedProminent)
                }.foregroundStyle(.white).padding(24)
            }
        }.task(id: retryID) { await model.start(server: server, watch: watch) }
            .onDisappear { model.stop() }
    }
}
