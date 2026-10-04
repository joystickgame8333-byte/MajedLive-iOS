import Foundation

enum NTVProvider {
    static let origin = URL(string: "https://ntv.cx")!
    struct Catalog: Decodable {
        let success: Bool
        let all: [Event]?
        let live: [Event]?
    }
    struct Event: Decodable {
        struct Teams: Decodable {
            struct Side: Decodable { let name: String? }
            let home: Side?
            let away: Side?
        }
        struct Source: Decodable { let source: String; let id: String }
        let id: String
        let title: String
        let category: String?
        let date: Double?
        let live: Bool?
        let teams: Teams?
        let sources: [Source]?

        func match() throws -> Match? {
            // Exact category matching excludes American football and non-match 24/7 entries.
            guard category?.lowercased() == "football", let date, date > 0,
                  let home = MatchInformation.text(teams?.home?.name),
                  let away = MatchInformation.text(teams?.away?.name) else { return nil }
            let start = Date(timeIntervalSince1970: date / 1000)
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Riyadh")
            formatter.dateFormat = "yyyy-MM-dd"
            let day = formatter.string(from: start)
            formatter.dateFormat = "HH:mm"
            let ready = !(sources ?? []).isEmpty
            let payload: [String: Any] = [
                "id": "ntv:" + id, "provider": "ntv", "date": day, "time": formatter.string(from: start),
                "state": live == true ? "live" : "upcoming", "state_text": live == true ? "مباشر" : "حسب جدول المصدر",
                "home_team": ["name": home], "away_team": ["name": away],
                "tournament": ["id": "ntv-football", "name": "كرة القدم · NTV"],
                "watch_ready": ready, "watch_available": ready, "site_watch_enabled": true,
                "watch_url": NTVProvider.origin.appendingPathComponent("watch/kobra").appendingPathComponent(id).absoluteString
            ]
            return try JSONDecoder().decode(Match.self, from: JSONSerialization.data(withJSONObject: payload))
        }
    }

    static func football(_ catalog: Catalog, date: String) throws -> [Match] {
        var seen = Set<String>()
        // Live entries take precedence over duplicates in the all-events collection.
        return try ((catalog.live ?? []) + (catalog.all ?? [])).compactMap { event in
            guard seen.insert(event.id).inserted, let match = try event.match(), match.date == date else { return nil }
            return match
        }.sorted { $0.time < $1.time }
    }

    static func matches(date: String) async throws -> [Match] {
        let url = NTVProvider.origin.appendingPathComponent("api/get-matches")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "server", value: "kobra"), URLQueryItem(name: "type", value: "both")]
        let (data, _) = try await PublishedStream.request(components.url!, headers: ["Accept": "application/json"])
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.success else { throw APIError.server("تعذّر تحديث جدول NTV.") }
        return try football(catalog, date: date)
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
    static func captured(_ pattern: String, in html: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: html).map { String(html[$0]) } ?? ""
            }
        }
    }
    static func embedServers(html: String, page: URL) -> [StreamServer] {
        let select = captured(#"<select\b[^>]*id=["']streamSelect["'][^>]*>(.*?)</select>"#, in: html).first?.first ?? ""
        var options = captured(#"<option\b[^>]*value=["']([^"']+)["'][^>]*>(.*?)</option>"#, in: select)
        if options.isEmpty {
            // Only the site's actual player iframe; never unrelated ads or tracking frames.
            options = captured(#"<iframe\b[^>]*id=["']streamPlayer["'][^>]*src=["']([^"']+)["']"#, in: html)
                .map { [$0[0], "بث NTV"] }
        }
        var seen = Set<URL>()
        return options.enumerated().compactMap { index, values in
            guard let url = URL(string: unescape(values[0]), relativeTo: page)?.absoluteURL,
                  url.scheme == "https", url.user == nil, url.password == nil, url.host != nil,
                  seen.insert(url).inserted else { return nil }
            let title = unescape(values[1]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return StreamServer(id: "ntv-server-\(index)", name: title.isEmpty ? "بث \(index + 1)" : title,
                type: "iframe", url: url.absoluteString, enabled: true, is_default: index == 0, priority: index)
        }
    }
    static func source(page: URL) async throws -> BroadcastSource {
        guard page.scheme == "https", page.host == origin.host,
              page.path.hasPrefix("/watch/") || page.path.hasPrefix("/channel/") else {
            throw APIError.server("رابط NTV غير صالح.")
        }
        let (data, _) = try await PublishedStream.request(page, headers: ["Referer": origin.absoluteString])
        guard let html = String(data: data, encoding: .utf8) else { throw APIError.server("تعذّر قراءة مصدر NTV.") }
        let servers = embedServers(html: html, page: page)
        guard !servers.isEmpty else { throw APIError.server("لم ينشر NTV مشغّلًا لهذه المباراة أو القناة حاليًا.") }
        return BroadcastSource(id: "ntv", name: "NTV", watchURL: page, servers: servers)
    }

    struct ChannelPage: Decodable {
        let success: Bool
        let channels: [Channel]
        let has_more: Bool?
    }
    struct Channel: Decodable {
        let channel_id: String
        let channel_name: String
        let channel_code: String?
        let server: String
        var watchURL: URL? {
            let slug = channel_name.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
                .replacingOccurrences(of: "[^a-zA-Z0-9-]", with: "", options: .regularExpression)
            switch server {
            case "cdnlive":
                guard !slug.isEmpty else { return nil }
                var parts = URLComponents(url: NTVProvider.origin.appendingPathComponent("channel/titan").appendingPathComponent(slug), resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "code", value: MatchInformation.text(channel_code) ?? "us")]
                return parts.url
            case "hesgoales": return slug.isEmpty ? nil : NTVProvider.origin.appendingPathComponent("channel/falcon").appendingPathComponent(slug)
            case "scorpion": return NTVProvider.origin.appendingPathComponent("channel/scorpion").appendingPathComponent(channel_name)
            case "dlhd": return NTVProvider.origin.appendingPathComponent("channel/phoenix").appendingPathComponent(channel_id)
            default: return nil
            }
        }
    }
    static func channels() async throws -> [LiveChannel] {
        var result: [LiveChannel] = []
        var seen = Set<String>()
        // NTV includes entertainment channels; import the published beIN sports collection only.
        for offset in stride(from: 0, to: 250, by: 50) {
            try Task.checkCancellation()
            var url = URLComponents(url: NTVProvider.origin.appendingPathComponent("api/get-channels"), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "q", value: "bein")]
            let (data, _) = try await PublishedStream.request(url.url!)
            let page = try JSONDecoder().decode(ChannelPage.self, from: data)
            guard page.success else { throw APIError.server("تعذّر تحديث قنوات NTV.") }
            for channel in page.channels where channel.channel_name.lowercased().contains("bein") {
                guard let watch = channel.watchURL, seen.insert(watch.absoluteString).inserted else { continue }
                let id = "ntv:" + channel.server + ":" + channel.channel_id + ":" + (channel.channel_code ?? "")
                let server = StreamServer(id: id, name: "NTV · " + channel.server, type: "ntv_page", url: watch.absoluteString,
                    enabled: true, is_default: true, priority: 0)
                let code = MatchInformation.text(channel.channel_code).map { " · " + $0.uppercased() } ?? ""
                result.append(LiveChannel(id: id, name: channel.channel_name + code,
                    source: BroadcastSource(id: "ntv", name: "NTV", watchURL: watch, servers: [server])))
            }
            if page.has_more != true || page.channels.isEmpty { break }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum FootballSchedule {
    struct Result { let matches: [Match]; let unavailable: [String] }
    static func load(date: String) async -> Result {
        await withTaskGroup(of: (String, [Match]?).self) { group in
            group.addTask { ("ماجد", try? await MatchesAPI().load(date: date)) }
            group.addTask { ("NTV", try? await NTVProvider.matches(date: date)) }
            var matches: [Match] = []; var unavailable: [String] = []
            for await (provider, data) in group {
                if let data { matches += data } else { unavailable.append(provider) }
            }
            return Result(matches: matches.sorted {
                if $0.isLive != $1.isLive { return $0.isLive }
                if $0.time != $1.time { return $0.time < $1.time }
                return $0.id < $1.id
            }, unavailable: unavailable.sorted())
        }
    }
}
