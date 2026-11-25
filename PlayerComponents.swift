import SwiftUI

enum PlayerPanel: String, Identifiable {
    case sources, quality
    var id: String { rawValue }
}

struct PlayerHeading: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "chevron.backward")
                    .font(.headline).frame(width: 44, height: 44)
                    .background(.primary.opacity(0.06), in: Circle())
            }.buttonStyle(.plain)
                .accessibilityLabel("الرجوع")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold()).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 16)
    }
}

struct PlayerDetails: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let sources: [BroadcastSource]
    let activeSourceID: String?
    let activeServerName: String?
    let quality: String
    let notice: String?
    let selectSource: (BroadcastSource) -> Void
    let expand: () -> Void
    let chooseSource: () -> Void
    let chooseQuality: () -> Void
    let retry: () -> Void
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let notice {
                Label(notice, systemImage: "arrow.triangle.2.circlepath").font(.caption)
                    .foregroundStyle(colors.accent).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.card, in: RoundedRectangle(cornerRadius: 14))
            }
            ViewThatFits(in: .horizontal) {
                HStack { sourceHeading; Spacer(minLength: 8); sourceListButton }
                VStack(alignment: .leading, spacing: 2) { sourceHeading; sourceListButton }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sources) { source in
                        let active = source.id == activeSourceID
                        Button { selectSource(source) } label: {
                            Label(source.name, systemImage: active ? "checkmark.circle.fill" : "play.circle")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 15).frame(minHeight: 44)
                                .foregroundStyle(active ? Color.white : Color.primary)
                                .background(active ? colors.action : colors.card, in: Capsule())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(active ? [.isSelected] : [])
                            .accessibilityIdentifier("broadcast-provider-\(source.id)")
                    }
                }
            }
            if let activeServerName {
                Text(activeServerName).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { playerActions }
                VStack(alignment: .leading, spacing: 2) { playerActions }
            }
        }
    }

    private var sourceHeading: some View { Text("مصادر البث").font(.title3.bold()).fixedSize() }

    private var sourceListButton: some View {
        Button(action: chooseSource) {
            Label("كل السيرفرات", systemImage: "list.bullet").font(.subheadline.weight(.medium))
                .padding(.horizontal, 8).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(colors.accent).accessibilityIdentifier("broadcast-source-list")
    }

    @ViewBuilder private var playerActions: some View {
        action("الجودة", quality, "slider.horizontal.3", chooseQuality)
        action("ملء الشاشة", nil, "arrow.up.left.and.arrow.down.right", expand)
        action("إعادة تحميل", nil, "arrow.clockwise", retry)
    }

    private func action(_ title: String, _ subtitle: String?, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol).font(.footnote.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary) }
            }.fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9).frame(minHeight: 44)
        }.buttonStyle(.plain)
    }
}

struct PlayerFailure: View {
    let message: String
    let canChange: Bool
    let retry: () -> Void
    let change: () -> Void
    @State private var details = false
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Text("هذا البث غير متاح الآن").font(.headline)
                HStack(spacing: 20) {
                    Button("أعد المحاولة", action: retry).buttonStyle(.bordered)
                    if canChange { Button("اختر بثًا آخر", action: change).buttonStyle(.borderedProminent) }
                }
                Button("تفاصيل المشكلة") { details = true }.font(.caption).foregroundStyle(.gray)
            }.padding(20).foregroundStyle(.white).tint(.mint)
        }.alert("تفاصيل البث", isPresented: $details) { Button("تم", role: .cancel) {} } message: { Text(message) }
    }
}

struct PlayerOptions: View {
    @Environment(\.dismiss) private var dismiss
    let panel: PlayerPanel
    let playback: Playback
    let selectedID: String?
    let failed: Set<String>
    let qualities: [StreamQuality]
    let qualityID: Int
    let selectServer: (Playback.Choice) -> Void
    let selectQuality: (StreamQuality) -> Void
    var body: some View {
        NavigationStack {
            List {
                if panel == .sources {
                    ForEach(playback.sources) { source in
                        Section(source.name) {
                            ForEach(playback.choices.filter { $0.source.id == source.id }) { choice in
                                Button { selectServer(choice) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: selectedID == choice.id ? "checkmark.circle.fill" : "play.circle")
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(choice.server.name).font(.headline)
                                            if failed.contains(choice.id) {
                                                Text("تعذّر في المحاولة السابقة").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.vertical, 6)
                                }.accessibilityAddTraits(selectedID == choice.id ? [.isSelected] : [])
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(qualities) { quality in
                            Button { selectQuality(quality) } label: {
                                HStack { Text(quality.label); Spacer(); if quality.id == qualityID { Image(systemName: "checkmark") } }
                            }
                        }
                        if qualities.isEmpty {
                            Text("لم يوفّر هذا المصدر قائمة جودة للتطبيق. إذا ظهر ترس داخل الفيديو، يمكنك تغيير الجودة منه.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } footer: { if !qualities.isEmpty { Text("تظهر هنا الجودات التي يوفرها البث فقط.") } }
                }
            }.navigationTitle(panel == .sources ? "اختر البث" : "جودة الصورة")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}
