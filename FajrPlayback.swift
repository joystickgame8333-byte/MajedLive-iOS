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
        throw APIError.server("قائمة بث الفجر غير متاحة الآن. جرّب مصدر بث آخر.")
    }
}

