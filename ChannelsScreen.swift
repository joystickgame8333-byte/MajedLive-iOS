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
            (provider == "all" || channel.source.id == provider) && (allRegions || channel.region == "arabic") &&
                (search.isEmpty || channel.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    SearchField(text: $search, prompt: "ابحث عن قناة")
                    ProviderPicker(selection: $provider, options: [("all", "الكل"), ("fajr", "الفجر"), ("ntv", "NTV")])
                    Toggle("إظهار القنوات الدولية", isOn: $allRegions).font(.subheadline).tint(colors.action)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(colors.card, in: RoundedRectangle(cornerRadius: 14))
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
                    channelGroups
                }.padding(.horizontal, 16).padding(.vertical, 14)
            }.background(colors.background)
                .safeAreaInset(edge: .top, spacing: 0) {
                    FootballSectionHeader(title: "القنوات", subtitle: FootballBrand.name, icon: "play.tv.fill") {
                        Text(channels.count.formatted())
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(colors.accent)
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .background(colors.highlight, in: Capsule())
                            .accessibilityLabel("\(channels.count) قناة")
                    }
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

    private var channelGroups: some View {
        let grouped = Dictionary(grouping: channels) { $0.source.id }
        var seen = Set<String>()
        let sources = channels.map(\.source).filter { seen.insert($0.id).inserted }
        return ForEach(sources) { source in
            VStack(alignment: .leading, spacing: 0) {
                Label(source.name, systemImage: "tv")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .background(colors.highlight.opacity(0.65))
                    .accessibilityAddTraits(.isHeader)
                ForEach(grouped[source.id, default: []]) { channel in
                    Rectangle().fill(colors.divider).frame(height: 1).accessibilityHidden(true)
                    channelRow(channel)
                }
            }.background(colors.card, in: RoundedRectangle(cornerRadius: 17))
                .clipShape(RoundedRectangle(cornerRadius: 17))
        }
    }

    private func channelRow(_ channel: LiveChannel) -> some View {
        Button { Task { await open(channel) } } label: {
            HStack(spacing: 12) {
                Image(systemName: "tv.fill").font(.subheadline).foregroundStyle(colors.accent)
                    .frame(width: 40, height: 40)
                    .background(colors.highlight, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name).font(.subheadline.bold()).lineLimit(2)
                    if channel.source.servers.count > 1 {
                        Text("\(channel.source.servers.count) بثوث متاحة").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Group {
                    if opening == channel.id { ProgressView() }
                    else { Image(systemName: "play.fill").font(.footnote.weight(.bold)).foregroundStyle(colors.accent) }
                }.frame(width: 44, height: 44)
            }.padding(.horizontal, 13).padding(.vertical, 9).contentShape(Rectangle())
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
