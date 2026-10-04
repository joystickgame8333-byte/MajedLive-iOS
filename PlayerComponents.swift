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
            Button(action: close) { Image(systemName: "chevron.right").font(.headline).frame(width: 44, height: 44) }
                .accessibilityLabel("الرجوع")
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold()).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 12)
    }
}

struct PlayerDetails: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let title: String
    let provider: String
    let sourceNumber: Int
    let sourceCount: Int
    let quality: String
    let notice: String?
    let expand: () -> Void
    let chooseSource: () -> Void
    let chooseQuality: () -> Void
    let retry: () -> Void
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let notice {
                Label(notice, systemImage: "arrow.triangle.2.circlepath").font(.caption)
                    .foregroundStyle(colors.accent).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.card, in: RoundedRectangle(cornerRadius: 14))
            }
            Text(title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(provider, systemImage: "tv").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(sourceCount) مصادر بث").font(.caption).foregroundStyle(.secondary)
            }
            Button(action: expand) {
                Label("شاهد بملء الشاشة", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.headline).frame(maxWidth: .infinity).padding(16)
            }.buttonStyle(.plain).foregroundStyle(.white)
                .background(colors.accent, in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                PlayerSettingButton(title: "البث", value: "بث \(sourceNumber)", symbol: "play.rectangle", action: chooseSource)
                PlayerSettingButton(title: "الجودة", value: quality, symbol: "slider.horizontal.3", action: chooseQuality)
            }
            HStack {
                Text("إذا توقف الفيديو، جرّب بثًا آخر.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: retry) { Label("إعادة تحميل", systemImage: "arrow.clockwise").font(.caption.bold()) }
            }.padding(.top, 4)
        }
    }
}

private struct PlayerSettingButton: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let title: String
    let value: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                HStack { Text(value).font(.subheadline.bold()).lineLimit(1); Spacer(); Image(systemName: "chevron.down").font(.caption2) }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.card(dark: scheme == .dark), in: RoundedRectangle(cornerRadius: 16))
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
    let servers: [StreamServer]
    let selectedID: String?
    let failed: Set<String>
    let qualities: [StreamQuality]
    let qualityID: Int
    let selectServer: (StreamServer) -> Void
    let selectQuality: (StreamQuality) -> Void
    var body: some View {
        NavigationStack {
            List {
                if panel == .sources {
                    Section {
                        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                            Button { selectServer(server) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: selectedID == server.id ? "checkmark.circle.fill" : "play.circle")
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("بث \(index + 1)").font(.headline)
                                        Text(failed.contains(server.id) ? "لم يعمل في المحاولة السابقة" : server.name)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }.padding(.vertical, 6)
                            }
                        }
                    } footer: { Text("يجرب التطبيق مصدرًا بديلًا عند الفشل، ويمكنك الاختيار يدويًا.") }
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
