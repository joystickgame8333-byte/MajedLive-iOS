import SwiftUI

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("مسح البحث")
            }
        }.padding(13).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ProviderPicker: View {
    @Binding var selection: String
    let options: [(String, String)]
    var body: some View {
        Picker("المصدر", selection: $selection) {
            ForEach(options.indices, id: \.self) { index in Text(options[index].1).tag(options[index].0) }
        }.pickerStyle(.segmented)
    }
}

struct ChannelsScreen: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var ntvChannels: [LiveChannel] = []
    @State private var provider = "all"
    @State private var allRegions = false
    @State private var search = ""
    @State private var loading = false
    @State private var loadError: String?
    @State private var opening: String?
    @State private var message: String?
    @State private var playback: Playback?
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }
    private var channels: [LiveChannel] {
        (ChannelCatalog.channels + ntvChannels).filter { channel in
            let source = channel.id.hasPrefix("ntv:") ? "ntv" : "fajr"
            return (provider == "all" || source == provider) && (allRegions || channel.region == "arabic") &&
                (search.isEmpty || channel.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("القنوات المباشرة").font(.title2.bold())
                        Text("اختر قناة، ثم شاهد مباشرة")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    SearchField(text: $search, prompt: "ابحث عن قناة")
                    ProviderPicker(selection: $provider, options: [("all", "الكل"), ("fajr", "الفجر"), ("ntv", "NTV")])
                    Toggle("إظهار القنوات الدولية أيضًا", isOn: $allRegions).font(.caption).tint(colors.accent)
                    if let loadError {
                        HStack {
                            Text(loadError).font(.caption)
                            Spacer()
                            Button("إعادة المحاولة") { Task { await refresh() } }.font(.caption.bold()).disabled(loading)
                        }.padding().background(colors.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if loading { ProgressView("تحديث القنوات…").font(.caption).frame(maxWidth: .infinity) }
                    if channels.isEmpty && !loading {
                        VStack(spacing: 12) {
                            Image(systemName: "tv").font(.largeTitle)
                            Text("لا توجد قنوات تطابق اختيارك").font(.subheadline)
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(channels) { channel in
                            channelCard(channel)
                        }
                    }
                }.padding(20)
            }.background(colors.background)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Label("القنوات", systemImage: "play.tv.fill").font(.title3.bold())
                        Spacer()
                        Text("\(channels.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding(.horizontal, 20).padding(.vertical, 16)
                        .background(colors.card.ignoresSafeArea(edges: .top))
                }
                .toolbar(.hidden, for: .navigationBar)
                .refreshable { await refresh() }
                .task { if ntvChannels.isEmpty { await refresh() } }
                .fullScreenCover(item: $playback) { PlayerScreen(playback: $0) }
                .alert("القناة", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("حسنًا", role: .cancel) { message = nil }
                } message: { Text(message ?? "") }
        }
    }

    private func channelCard(_ channel: LiveChannel) -> some View {
        Button { Task { await open(channel) } } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "play.tv.fill").font(.title2).foregroundStyle(colors.accent)
                    Spacer()
                    if opening == channel.id { ProgressView() }
                    else { Image(systemName: "play.circle.fill").foregroundStyle(colors.accent) }
                }
                Text(channel.name).font(.subheadline.bold()).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(channel.source.servers.count > 1 ? "\(channel.source.servers.count) مصادر · " + channel.source.name : channel.source.name).font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                .background(colors.card, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).disabled(opening != nil)
    }

    @MainActor private func refresh() async {
        guard !loading else { return }
        loading = true; loadError = nil
        defer { loading = false }
        do {
            let result = try await NTVProvider.channels()
            try Task.checkCancellation()
            ntvChannels = result
        } catch {
            if !Task.isCancelled { loadError = "تعذّر تحديث قنوات NTV. قنوات الفجر تبقى متاحة." }
        }
    }
    @MainActor private func open(_ channel: LiveChannel) async {
        guard opening == nil else { return }
        opening = channel.id
        defer { opening = nil }
        do {
            let source = channel.source
            guard let server = source.servers.first else { throw APIError.server("هذه القناة غير متاحة حاليًا.") }
            playback = source.playback(title: channel.name, server: server)
        } catch {
            message = (error as? APIError)?.errorDescription ?? "تعذّر تجهيز القناة. حاول مجددًا."
        }
    }
}
