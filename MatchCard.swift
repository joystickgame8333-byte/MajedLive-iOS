import SwiftUI

struct MatchCard: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let match: Match
    let checking: Bool
    let action: () -> Void
    @State private var details = false
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(match.providerTitle).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(match.isLive ? "● مباشر" : match.state_text ?? "لم تبدأ")
                    .font(.caption2.bold()).foregroundStyle(match.isLive ? colors.accent : Color.secondary)
            }
            HStack(spacing: 10) {
                MatchTeam(team: match.home_team)
                VStack(spacing: 6) {
                    Text(match.hasScore ? match.scoreText : match.time)
                        .font(.title2.bold()).monospacedDigit().environment(\.layoutDirection, .leftToRight)
                    if match.isLive && match.elapsed_seconds != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(match.clockText(now: context.date) ?? "مباشر").font(.caption.bold()).monospacedDigit().foregroundStyle(colors.accent)
                        }
                    } else if match.hasScore {
                        Text("بدأت \(match.time)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let added = match.added_minutes, added > 0 { Text("+\(added)").font(.caption2).foregroundStyle(.secondary) }
                }.frame(width: 94)
                MatchTeam(team: match.away_team)
            }
            if let channel = match.broadcastChannel {
                Label(channel, systemImage: "tv").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 12) {
                Button(action: action) {
                    HStack(spacing: 8) {
                        if checking { ProgressView().tint(.white) }
                        else { Image(systemName: match.playbackURL == nil ? "clock" : "play.fill") }
                        Text(checking ? "فتح البث…" : match.playbackURL == nil ? "البث لم يُنشر" : "شاهد الآن")
                            .font(.subheadline.bold())
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(match.playbackURL == nil ? colors.accent : .white)
                        .background(match.playbackURL == nil ? colors.accent.opacity(0.08) : colors.accent, in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).disabled(match.playbackURL == nil).accessibilityIdentifier("watch-\(match.id)")
                Button { details = true } label: {
                    Image(systemName: "info.circle").font(.title3).frame(width: 44, height: 44)
                        .background(colors.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                }.accessibilityLabel("معلومات المباراة")
            }
        }.padding(16).background(colors.card, in: RoundedRectangle(cornerRadius: 22))
            .sheet(isPresented: $details) { MatchDetails(match: match) }
    }
}

private struct MatchTeam: View {
    let team: Team
    var body: some View {
        VStack(spacing: 8) {
            RemoteLogo(path: team.logo, size: 36)
            Text(team.name).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
        }.frame(maxWidth: .infinity)
    }
}

private struct MatchDetails: View {
    @Environment(\.dismiss) private var dismiss
    let match: Match
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(match.home_team.name) × \(match.away_team.name)").font(.headline)
                    row("البطولة", match.tournament.name)
                    row("التاريخ", MatchInformation.dateTitle(match.date))
                    row("البداية", match.time)
                }
                Section("النقل والمعلومات") {
                    row("مصدر البث", match.providerTitle)
                    row("القناة الناقلة", match.broadcastChannel ?? "لم يحددها المصدر")
                    if let commentator = match.commentatorName { row("المعلق", commentator) }
                    if let stadium = match.stadiumName { row("الملعب", stadium) }
                    if let round = match.roundTitle { row("الجولة", round) }
                }
            }.navigationTitle("عن المباراة").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }.font(.subheadline)
    }
}
