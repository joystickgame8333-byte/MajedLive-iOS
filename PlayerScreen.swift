import SwiftUI
import AVKit

struct PlaybackAttempts {
    var failed: Set<String> = []
    var automaticSwitches = 0
    mutating func next(after id: String, servers: [StreamServer]) -> StreamServer? {
        failed.insert(id)
        guard automaticSwitches < 2,
              let next = servers.first(where: { $0.playbackURL != nil && !failed.contains($0.id) }) else { return nil }
        automaticSwitches += 1
        return next
    }
}

struct PlayerLayout {
    let width: CGFloat
    let height: CGFloat
    let rotated: Bool
    let cinema: Bool
    init(size: CGSize, expanded: Bool, windowedLandscape: Bool = false) {
        rotated = expanded && size.height > size.width
        width = rotated ? size.height : size.width
        height = rotated ? size.width : size.height
        cinema = expanded || (size.width > size.height && !windowedLandscape)
    }
    var videoHeight: CGFloat { cinema ? height : min(width * 9 / 16, height * 0.5) }
}

struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let playback: Playback
    @StateObject private var model = UnifiedPlayerModel()
    @StateObject private var web = EmbeddedPlayerState()
    @State private var selectedID: String?
    @State private var retry = UUID()
    @State private var expanded = false
    @State private var windowedLandscape = false
    @State private var attempts = PlaybackAttempts()
    @State private var notice: String?
    @State private var handledFailure: String?
    @State private var panel: PlayerPanel?
    @State private var previousIdleTimer = false
    @State private var controlsVisible = true
    @State private var controlsActivity = UUID()
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }
    private var selected: StreamServer? {
        playback.servers.first { $0.id == selectedID } ?? playback.servers.first { $0.is_default == true } ?? playback.servers.first
    }
    private var loadingKey: String { (selected?.id ?? "none") + retry.uuidString }
    private var failure: String? { model.error ?? web.error }
    private var qualities: [StreamQuality] { model.embedded == nil ? model.qualities : web.qualities }
    private var qualityID: Int { model.embedded == nil ? model.selectedQuality : web.selectedQuality }
    private var qualityLabel: String { qualities.first { $0.id == qualityID }?.label ?? "حسب البث" }
    init(playback: Playback) {
        self.playback = playback
        _selectedID = State(initialValue: playback.initialServerID)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = PlayerLayout(size: geometry.size, expanded: expanded, windowedLandscape: windowedLandscape)
            VStack(spacing: 0) {
                PlayerHeading(title: playback.title, subtitle: playback.providerName, close: { dismiss() })
                    .frame(height: layout.cinema ? 0 : 64).clipped().opacity(layout.cinema ? 0 : 1)
                video(cinema: layout.cinema)
                    .frame(width: layout.width, height: layout.videoHeight)
                ScrollView {
                    PlayerDetails(title: playback.title, provider: playback.providerName,
                        sourceNumber: sourceNumber, sourceCount: playback.servers.count,
                        quality: qualityLabel, notice: notice,
                        expand: { expanded = true }, chooseSource: { panel = .sources },
                        chooseQuality: { panel = .quality }, retry: retryCurrent)
                        .padding(20).padding(.bottom, geometry.safeAreaInsets.bottom)
                }.frame(height: layout.cinema ? 0 : max(0, layout.height - layout.videoHeight - 64))
                    .clipped().opacity(layout.cinema ? 0 : 1)
            }
            .frame(width: layout.width, height: layout.height)
            .background(colors.background)
            .rotationEffect(.degrees(layout.rotated ? 90 : 0))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .statusBarHidden(layout.cinema)
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(edges: expanded ? .all : [])
        .task(id: loadingKey) { await load() }
        .onChange(of: model.error) { _ in handleFailure() }
        .onChange(of: web.error) { _ in handleFailure() }
        .onChange(of: model.isPlaying) { if $0 { notice = nil; revealControls() } }
        .onChange(of: web.started) { if $0 { notice = nil; revealControls() } }
        .task(id: controlsActivity) {
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard !Task.isCancelled, failure == nil, !model.loading, panel == nil,
                  model.isPlaying || web.started else { return }
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        }
        .onChange(of: panel) { _ in revealControls() }
        .onChange(of: expanded) { _ in revealControls() }
        .sheet(item: $panel) { choice in
            PlayerOptions(panel: choice, servers: playback.servers, selectedID: selected?.id,
                failed: attempts.failed, qualities: qualities, qualityID: qualityID,
                selectServer: choose, selectQuality: chooseQuality)
        }
        .onAppear(perform: beginViewing)
        .onDisappear(perform: endViewing)
    }

    private func beginViewing() {
        previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    private func endViewing() {
        model.stop(); web.reset()
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var sourceNumber: Int { (playback.servers.firstIndex { $0.id == selected?.id } ?? 0) + 1 }
    private func video(cinema: Bool) -> some View {
        ZStack {
            Color.black
            if let embedded = model.embedded {
                EmbeddedPlayerView(url: embedded, referrer: model.embeddedReferrer ?? playback.url, state: web).id(loadingKey)
            } else {
                NativePlayerSurface(player: model.player)
            }
            if model.loading {
                VStack(spacing: 10) { ProgressView().tint(.white); Text("تجهيز البث…").font(.caption) }
                    .foregroundStyle(.white).allowsHitTesting(false)
            }
            if model.embedded != nil && !web.started && !web.awaitingTap && failure == nil {
                VStack { Text("تحميل البث… يمكنك اختيار بث آخر").font(.caption).padding(10)
                    .background(.black.opacity(0.75), in: Capsule()); Spacer() }
                    .padding(.top, cinema ? 55 : 12).foregroundStyle(.white).allowsHitTesting(false)
            }
            if web.awaitingTap && !web.started && failure == nil {
                Button(action: web.play) {
                    Label("اضغط لتشغيل البث", systemImage: "play.fill").font(.headline).padding(16)
                        .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white)
                }
            }
            if let failure {
                PlayerFailure(message: failure, canChange: playback.servers.count > 1,
                    retry: retryCurrent, change: { panel = .sources })
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
        .overlay(alignment: .topTrailing) {
            if controlsVisible || failure != nil {
                HStack {
                    if cinema {
                        Button { dismiss() } label: { Image(systemName: "xmark").padding(12).background(.black.opacity(0.45), in: Circle()) }
                            .accessibilityLabel("إغلاق المشاهدة")
                        Spacer()
                    }
                    Button {
                        if cinema { expanded = false; windowedLandscape = true }
                        else { expanded = true; windowedLandscape = false }
                        revealControls()
                    } label: {
                        Image(systemName: cinema ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .padding(12).background(.black.opacity(0.45), in: Circle())
                    }.accessibilityLabel(cinema ? "تصغير" : "ملء الشاشة").accessibilityIdentifier("player-fullscreen")
                }.font(.subheadline.bold()).foregroundStyle(.white)
                    .padding(.horizontal, cinema ? 32 : 10).padding(.top, 10)
            }
        }
        .overlay(alignment: .bottom) {
            if controlsVisible && (model.embedded == nil || cinema) {
                HStack(spacing: 12) {
                    if model.embedded == nil && model.player != nil {
                        Button { model.togglePlayback(); revealControls() } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").padding(12).background(.black.opacity(0.45), in: Circle())
                        }.accessibilityLabel(model.isPlaying ? "إيقاف مؤقت" : "تشغيل")
                        Button { model.toggleMute(); revealControls() } label: {
                            Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").padding(12).background(.black.opacity(0.45), in: Circle())
                        }.accessibilityLabel(model.isMuted ? "تشغيل الصوت" : "كتم الصوت")
                    }
                    if cinema {
                        Spacer()
                        Button { panel = .sources } label: { Label("البث \(sourceNumber)", systemImage: "play.rectangle").padding(10).background(.black.opacity(0.45), in: Capsule()) }
                        Button { panel = .quality } label: { Label(qualityLabel, systemImage: "slider.horizontal.3").padding(10).background(.black.opacity(0.45), in: Capsule()) }
                    }
                }.font(.subheadline.bold()).foregroundStyle(.white)
                    .padding(.horizontal, cinema ? 32 : 12).padding(.bottom, model.embedded != nil ? 46 : 12)
            }
        }
    }

    private func revealControls() {
        controlsVisible = true
        controlsActivity = UUID()
    }

    @MainActor private func load() async {
        web.reset(); handledFailure = nil; revealControls()
        guard let selected else { return }
        await model.load(server: selected, watch: playback.url)
        guard !Task.isCancelled, model.embedded != nil else { return }
        do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
        guard !Task.isCancelled, !web.started, !web.awaitingTap, web.error == nil else { return }
        web.error = "لم يبدأ الفيديو من هذا المصدر خلال وقت الانتظار."
    }
    private func handleFailure() {
        guard failure != nil, handledFailure != loadingKey, let selected else { return }
        handledFailure = loadingKey
        if let next = attempts.next(after: selected.id, servers: playback.servers) {
            notice = "لم يستجب البث السابق؛ نجرب بثًا بديلًا."
            selectedID = next.id
        }
    }
    private func choose(_ server: StreamServer) {
        attempts.automaticSwitches = 0; attempts.failed.remove(server.id)
        notice = nil; selectedID = server.id; retry = UUID(); panel = nil
    }
    private func retryCurrent() {
        attempts.automaticSwitches = 0
        if let selected { attempts.failed.remove(selected.id) }
        notice = nil; retry = UUID()
    }
    private func chooseQuality(_ quality: StreamQuality) {
        if model.embedded == nil { model.selectQuality(quality) } else { web.select(quality) }
        panel = nil
    }
}

struct NativePlayerSurface: UIViewRepresentable {
    let player: AVPlayer?
    func makeUIView(context: Context) -> VideoSurface { VideoSurface() }
    func updateUIView(_ view: VideoSurface, context: Context) { view.playerLayer.player = player }
    static func dismantleUIView(_ view: VideoSurface, coordinator: ()) { view.playerLayer.player = nil }
    final class VideoSurface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .black; playerLayer.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
