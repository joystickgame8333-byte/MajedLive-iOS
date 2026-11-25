import SwiftUI

enum FootballBrand {
    static let name = "الكرة عمر"
}

struct FootballSectionHeader<Action: View>: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        let colors = ThemeColors(theme: theme, dark: scheme == .dark)
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(colors.action, in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            action()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(colors.card.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(colors.divider).frame(height: 1) }
    }
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
    var availableServers: [StreamServer] { servers.filter { $0.playbackURL != nil } }

    func playback(title: String, server: StreamServer) -> Playback {
        Playback(title: title, sources: [self],
                 initialChoiceID: Playback.Choice(source: self, server: server).id)
    }
}

enum BroadcastCatalog {
    static func sources(for match: Match, alongside matches: [Match] = []) async throws -> [BroadcastSource] {
        guard let watch = match.playbackURL else { return [] }
        let secondary = Task { await alternate(for: match, alongside: matches) }
        defer { secondary.cancel() }
        do {
            let primary = try await source(for: match, watch: watch)
            let additional = await secondary.value
            if let additional { return [primary, additional] }
            return [primary]
        } catch {
            let additional = await secondary.value
            if let additional { return [additional] }
            throw error
        }
    }

    private static func source(for match: Match, watch: URL) async throws -> BroadcastSource {
        if match.providerID == "ntv" { return try await NTVProvider.source(page: watch) }
        let servers = try await WatchAPI().servers(publishedURL: watch)
        if watch.host == Site.origin.host, watch.path == "/watch",
           servers.allSatisfy({ $0.type == "iframe" && $0.playbackURL?.host == "player.majedfiles.site" }) {
            let server = StreamServer(id: "majed-watch", name: "ماجد لايف", type: "majed_watch",
                url: watch.absoluteString, enabled: true, is_default: true, priority: 0)
            return BroadcastSource(id: "majed", name: "ماجد لايف", watchURL: watch, servers: [server])
        }
        return BroadcastSource(id: "majed", name: "ماجد لايف", watchURL: watch, servers: servers)
    }

    private static func alternate(for match: Match, alongside matches: [Match]) async -> BroadcastSource? {
        guard match.isLive else { return nil }
        let candidates = matches.filter { candidate in
            candidate.providerID != match.providerID && candidate.isLive && candidate.playbackURL != nil
                && NTVProvider.matchesFixture(candidate, match)
        }
        if candidates.count == 1, let candidate = candidates.first, let watch = candidate.playbackURL {
            return try? await source(for: candidate, watch: watch)
        }
        guard match.providerID == "majed" else { return nil }
        return await NTVProvider.alternateSource(for: match)
    }

    static func playback(from sources: [BroadcastSource], title: String) -> Playback? {
        let playback = Playback(title: title, sources: sources)
        return playback.choices.isEmpty ? nil : playback
    }
}

struct LiveChannel: Identifiable {
    let id: String
    let name: String
    let source: BroadcastSource
    var region = "arabic"
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

