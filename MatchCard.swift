import SwiftUI

struct MatchCard: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let match: Match
    let checking: Bool
    let anotherMatchIsOpening: Bool
    let action: () -> Void
    @State private var details = false
    private var colors: ThemeColors { ThemeColors(theme: theme, dark: scheme == .dark) }
    var body: some View {
        HStack(spacing: 10) {
            Button { details = true } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        teamRow(match.home_team)
                        teamRow(match.away_team)
                        if let channel = match.broadcastChannel {
                            Label(channel, systemImage: "tv").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 3)
                    VStack(spacing: 4) {
                        Text(match.hasScore ? match.scoreText : match.time)
                            .font(.subheadline.weight(.bold)).monospacedDigit()
                            .environment(\.layoutDirection, .leftToRight)
                        if match.isLive {
                            MatchLiveClock(match: match).foregroundStyle(colors.accent)
                        } else if let status = match.state_text {
                            Text(status).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }.frame(minWidth: 54)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("معلومات \(match.home_team.name) و\(match.away_team.name)")
                .accessibilityIdentifier("details-\(match.id)")

            if match.playbackURL != nil {
                Button(action: action) {
                    Group {
                        if checking { ProgressView().tint(colors.accent) }
                        else { Image(systemName: "play.fill").font(.subheadline.weight(.semibold)).foregroundStyle(colors.accent) }
                    }.frame(width: 44, height: 44)
                        .background(colors.highlight, in: Circle())
                }.buttonStyle(.plain).disabled(anotherMatchIsOpening)
                    .accessibilityLabel("شاهد \(match.home_team.name) و\(match.away_team.name)")
                    .accessibilityIdentifier("watch-\(match.id)")
            }
        }.padding(.horizontal, 13).padding(.vertical, 11)
            .sheet(isPresented: $details) { MatchDetails(match: match) }
    }

    private func teamRow(_ team: Team) -> some View {
        HStack(spacing: 8) {
            RemoteLogo(path: team.logo, size: 21).accessibilityHidden(true)
            Text(team.name).font(.subheadline.weight(.medium)).lineLimit(2)
        }
    }
}

struct FeaturedMatchCard: View {
    @Environment(\.appTheme) private var theme
    let match: Match
    let checking: Bool
    let anotherMatchIsOpening: Bool
    let action: () -> Void
    @State private var details = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 7) {
                Circle().fill(Color(red: 0.44, green: 0.94, blue: 0.67)).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("مباشر الآن").font(.caption.weight(.bold))
                Spacer(minLength: 6)
                Text(match.tournament.name).font(.caption.weight(.medium)).lineLimit(2)
            }
            HStack(spacing: 8) {
                MatchTeam(team: match.home_team)
                VStack(spacing: 4) {
                    Text(match.hasScore ? match.scoreText : match.time)
                        .font(.title.bold()).monospacedDigit()
                        .environment(\.layoutDirection, .leftToRight)
                    MatchLiveClock(match: match)
                }.frame(minWidth: 76)
                MatchTeam(team: match.away_team)
            }
            HStack(spacing: 10) {
                Button(action: action) {
                    HStack(spacing: 8) {
                        if checking { ProgressView().tint(.black) }
                        else { Image(systemName: "play.fill") }
                        Text(checking ? "فتح البث…" : "شاهد الآن")
                    }.font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.black)
                        .background(theme.accent(dark: true), in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).disabled(anotherMatchIsOpening)
                    .accessibilityIdentifier("watch-\(match.id)")
                Button { details = true } label: {
                    Image(systemName: "info.circle").font(.title3).frame(width: 44, height: 44)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain).accessibilityLabel("معلومات المباراة")
            }
        }.padding(16)
            .foregroundStyle(.white)
            .background {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.04, green: 0.12, blue: 0.11),
                                            Color(red: 0.06, green: 0.29, blue: 0.22)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        let center = CGPoint(x: width * 0.54, y: height * 0.48)
                        Path { field in
                            field.addRoundedRect(in: CGRect(x: 10, y: 10, width: max(0, width - 20), height: max(0, height - 20)),
                                                 cornerSize: CGSize(width: 14, height: 14), style: .continuous)
                            field.move(to: CGPoint(x: center.x, y: 10))
                            field.addLine(to: CGPoint(x: center.x, y: height - 10))
                            field.addEllipse(in: CGRect(x: center.x - 31, y: center.y - 31, width: 62, height: 62))
                        }.stroke(.white.opacity(0.12), lineWidth: 1)
                    }.accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .sheet(isPresented: $details) { MatchDetails(match: match) }
    }
}

private struct MatchLiveClock: View {
    let match: Match
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 3) {
                Text(match.clockText(now: context.date) ?? "مباشر")
                if let added = match.added_minutes, added > 0 { Text("+\(added)").font(.caption2) }
            }.font(.caption.weight(.semibold)).monospacedDigit()
        }
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

#if DEBUG
private struct MatchCardPreviews: PreviewProvider {
    private static let fixture = """
    {
      "id":"preview","date":"2026-11-25","time":"20:45","state":"live","elapsed_seconds":2760,
      "home_team":{"name":"صباح","score":1},"away_team":{"name":"برشلونة","score":2},
      "tournament":{"name":"دوري أبطال أوروبا"},"broadcast":{"channel":"beIN SPORTS"},
      "watch_ready":true,"watch_available":true,"watch_url":"https://example.com/watch"
    }
    """

    @ViewBuilder static var previews: some View {
        if let match = try? JSONDecoder().decode(Match.self, from: Data(fixture.utf8)) {
            VStack(spacing: 16) {
                FeaturedMatchCard(match: match, checking: false, anotherMatchIsOpening: false) {}
                MatchCard(match: match, checking: true, anotherMatchIsOpening: true) {}
            }.padding().environment(\.layoutDirection, .rightToLeft)
                .previewDisplayName("مباشر وتحميل البث")
        }
    }
}
#endif
