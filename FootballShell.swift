import SwiftUI

enum FootballBrand {
    static let name = "الكرة عمر"
}

struct FootballShell: View {
    @EnvironmentObject private var updates: AppUpdates
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        TabView {
            MatchesScreen()
                .tabItem { Label("المباريات", systemImage: "soccerball") }
            ChannelsScreen()
                .tabItem { Label("القنوات", systemImage: "tv") }
            SettingsScreen(updates: updates, standalone: true)
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
        }
        .toolbarBackground(theme.card(dark: scheme == .dark), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

// A provider owns its watch-page context and servers. Adding another provider
// never changes which page authorizes the currently selected stream.
struct BroadcastSource: Identifiable {
    let id: String
    let name: String
    let watchURL: URL
    let servers: [StreamServer]
    var note: String? = nil
    func playback(title: String, server: StreamServer) -> Playback {
        Playback(title: title, url: watchURL, servers: servers,
                 providerName: name, initialServerID: server.id)
    }
}

enum BroadcastCatalog {
    static func sources(for match: Match) async throws -> [BroadcastSource] {
        guard let watch = match.playbackURL else { return [] }
        if match.providerID == "ntv" { return [try await NTVProvider.source(page: watch)] }
        let servers = try await WatchAPI().servers(publishedURL: watch)
        return servers.isEmpty ? [] : [BroadcastSource(id: "majed", name: "ماجد لايف", watchURL: watch, servers: servers)]
    }
}

struct LiveChannel: Identifiable {
    let id: String
    let name: String
    let source: BroadcastSource
    var playback: Playback? {
        guard let server = source.servers.first(where: { $0.playbackURL != nil }) else { return nil }
        return source.playback(title: name, server: server)
    }
}

enum ChannelCatalog {
    private static func channel(_ id: String, _ name: String, pages: [(String, String)]) -> LiveChannel {
        let servers = pages.enumerated().map { index, page in
            StreamServer(id: "fajr-\(id)-\(index)", name: page.0, type: "fajr_hls_page",
                         url: FajrStream.origin.appendingPathComponent(page.1).absoluteString,
                         enabled: true, is_default: index == 0, priority: index)
        }
        return LiveChannel(id: "fajr-" + id, name: name,
            source: BroadcastSource(id: "fajr-" + id, name: "تلفزيون الفجر", watchURL: FajrStream.origin, servers: servers))
    }
    static let channels: [LiveChannel] = [
        channel("one", "الفجر · قناة 1", pages: [("بث 1", "live-westbank-1.php"), ("بث 2", "live-westbank-1-a.php"), ("بث 3", "live-westbank-1-b.php")]),
        channel("hq", "الفجر · Full HD", pages: [("البث الرئيسي", "live-westbank-1-HQ.php")]),
        channel("two", "الفجر · قناة 2 (دولي)", pages: [("البث الرئيسي", "live-westbank-2.php")]),
        channel("three", "الفجر · قناة 3", pages: [("البث الرئيسي", "live-westbank-3.php")]),
        channel("four", "الفجر · قناة 4", pages: [("البث الرئيسي", "live-westbank-4.php")]),
        channel("five", "الفجر · قناة 5", pages: [("البث الرئيسي", "live-westbank-5.php")]),
        channel("international", "الفجر · دولي", pages: [("البث الرئيسي", "live-international.php")])
    ]
}

