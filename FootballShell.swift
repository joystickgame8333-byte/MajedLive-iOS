import SwiftUI

enum FootballBrand {
    static let name = "الكرة عمر"
}

struct FootballShell: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        TabView {
            MatchesScreen()
                .tabItem { Label("المباريات", systemImage: "soccerball") }
            ChannelsScreen()
                .tabItem { Label("القنوات", systemImage: "tv") }
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
    func playback(title: String, server: StreamServer) -> Playback {
        Playback(title: title, url: watchURL, servers: servers,
                 providerName: name, initialServerID: server.id)
    }
}

struct BroadcastSelection: Identifiable {
    let id = UUID()
    let title: String
    let sources: [BroadcastSource]
}

enum BroadcastCatalog {
    static func sources(for match: Match) async throws -> [BroadcastSource] {
        guard let watchURL = match.playbackURL else { return [] }
        let servers = try await WatchAPI().servers(publishedURL: watchURL)
        return [BroadcastSource(id: "majed", name: "ماجد لايف", watchURL: watchURL, servers: servers)]
    }
}

struct BroadcastSelectionScreen: View {
    let selection: BroadcastSelection
    let onSelect: (Playback) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(selection.title).font(.headline)
                    Text("اختر المصدر الذي تريد مشاهدة المباراة منه")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ForEach(selection.sources) { source in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(source.name, systemImage: "play.tv.fill").font(.headline)
                            ForEach(source.servers) { server in
                                Button {
                                    onSelect(source.playback(title: selection.title, server: server))
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "play.circle.fill").font(.title2)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(source.servers.count == 1 ? "شاهد عبر \(source.name)" : server.name)
                                                .font(.subheadline.bold())
                                            Text(source.servers.count == 1 ? server.name : source.name)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.left").font(.caption.bold())
                                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(colors.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                                }.buttonStyle(.plain).foregroundStyle(colors.accent)
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 20))
                    }
                }.padding(20)
            }.background(colors.background)
                .navigationTitle("اختر البث")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
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
    // Populate only after receiving real, published channel sources.
    static let channels: [LiveChannel] = []
}

struct ChannelsScreen: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var playback: Playback?
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("القنوات المباشرة").font(.title2.bold())
                    Text("قنواتك في مكان واحد").font(.subheadline).foregroundStyle(.secondary)
                    if ChannelCatalog.channels.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(colors.accent)
                            Text("لا توجد قنوات مضافة بعد").font(.headline)
                            Text("ستظهر هنا القنوات بعد إضافة مصادر بثها.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(30).frame(maxWidth: .infinity)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 24))
                    } else {
                        ForEach(ChannelCatalog.channels) { channel in
                            Button { playback = channel.playback } label: {
                                HStack {
                                    Label(channel.name, systemImage: "play.tv.fill").font(.headline)
                                    Spacer()
                                    Image(systemName: "play.circle.fill").font(.title2)
                                }.padding(20).background(colors.card, in: RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(.plain).disabled(channel.playback == nil)
                        }
                    }
                }.padding(20)
            }.background(colors.background)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Label(FootballBrand.name, systemImage: "soccerball").font(.title3.bold())
                        Spacer()
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                        .background(colors.card.ignoresSafeArea(edges: .top))
                }
                .toolbar(.hidden, for: .navigationBar)
                .fullScreenCover(item: $playback) { PlayerScreen(playback: $0) }
        }
    }
}
