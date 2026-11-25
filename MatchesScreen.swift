import SwiftUI

struct MatchesScreen: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(theme: appTheme, dark: colorScheme == .dark) }
    @StateObject private var model = ScheduleModel()
    @EnvironmentObject private var updates: AppUpdates
    @AppStorage("selectedLeague") private var selectedLeague = LeagueFilter.all
    @AppStorage("selectedLeagueTitle") private var selectedLeagueTitle = "كل الدوريات"
    @State private var day = 0
    @State private var showingFilters = false
    @State private var showingSearch = false
    @State private var liveOnly = false
    @State private var provider = "all"
    @State private var ntvServer = "kobra"
    @State private var search = ""
    @State private var playback: Playback?
    @State private var checkingMatch: String?
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase

    private var providerMatches: [Match] {
        guard provider == "all" else { return model.matches.filter { $0.providerID == provider } }
        let majed = Dictionary(grouping: model.matches.filter { $0.providerID == "majed" && $0.playbackURL != nil }, by: \.time)
        return model.matches.filter { match in
            guard match.providerID == "ntv", match.isLive else { return true }
            return majed[match.time]?.contains { $0.isLive && NTVProvider.matchesFixture($0, match) } != true
        }
    }
    private var filteredMatches: [Match] {
        LeagueFilter.matches(providerMatches, selected: selectedLeague).filter {
            (!liveOnly || $0.isLive) && (search.isEmpty || ($0.home_team.name + " " + $0.away_team.name + " " + $0.tournament.name).localizedCaseInsensitiveContains(search))
        }
    }
    private var featuredMatch: Match? {
        guard day == 0, search.isEmpty else { return nil }
        let playable = filteredMatches.filter { $0.isLive && $0.playbackURL != nil }
        return playable.first { $0.providerID == "majed" } ?? playable.first
    }
    private var leagues: [Competition] {
        var seen = Set<String>()
        return providerMatches.map(\.tournament).filter { seen.insert($0.filterKey).inserted }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    dateStrip
                    if showingSearch { SearchField(text: $search, prompt: "ابحث عن فريق أو بطولة") }
                    scheduleControls
                    if let error = model.error {
                        VStack(spacing: 12) {
                            Label(error, systemImage: "wifi.exclamationmark")
                            Button("إعادة المحاولة") { Task { await model.refresh(offset: day, ntvServer: ntvServer) } }
                        }.font(.subheadline).padding().frame(maxWidth: .infinity)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if model.loading && model.matches.isEmpty {
                        ProgressView("جاري تحميل المباريات…")
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else if filteredMatches.isEmpty && model.error == nil {
                        VStack(spacing: 14) {
                            Image(systemName: "sportscourt").font(.largeTitle).foregroundStyle(colors.accent)
                            Text("لا توجد مباريات تطابق اختيارك").font(.headline)
                            Text("اسحب للأسفل لتحديث الجدول").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 55)
                    } else {
                        if let featured = featuredMatch {
                            FeaturedMatchCard(match: featured, checking: checkingMatch == featured.id,
                                              anotherMatchIsOpening: checkingMatch != nil) {
                                Task { await open(featured) }
                            }
                        }
                        matchList(excluding: featuredMatch?.id)
                    }
                    if let updated = model.updated {
                        Text("آخر تحديث: \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 12)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 14)
            }
            .background(colors.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                header
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if updates.available != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(colors.accent)
                        Text("تحديث جديد متاح").font(.subheadline.weight(.medium))
                        Spacer(minLength: 8)
                        Button { updates.install() } label: {
                            if updates.installing { ProgressView() }
                            else { Text("تحديث").font(.subheadline.bold()) }
                        }.disabled(updates.installing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(colors.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(colors.accent.opacity(0.2), lineWidth: 1))
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(colors.background)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refresh(offset: day, ntvServer: ntvServer) }
            .task(id: "\(day)-\(ntvServer)-\(scenePhase == .active)-\(playback == nil)") {
                guard scenePhase == .active, playback == nil else { return }
                Task { await updates.check() }
                await model.refresh(offset: day, ntvServer: ntvServer)
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    await model.refresh(offset: day, ntvServer: ntvServer)
                    Task { await updates.check() }
                }
            }
            .onChange(of: day) { _ in model.matches = []; model.updated = nil; selectedLeague = LeagueFilter.all; if day != 0 { liveOnly = false } }
            .onChange(of: provider) { _ in selectedLeague = LeagueFilter.all }
            .sheet(isPresented: $showingFilters) {
                NavigationStack {
                    Form {
                        Section("مصدر الجدول") {
                            ProviderPicker(selection: $provider, options: [("all", "الكل"), ("majed", "ماجد"), ("ntv", "NTV")])
                            if provider != "majed" {
                                Picker("قسم NTV", selection: $ntvServer) {
                                    ForEach(NTVProvider.sections, id: \.self) { Text($0.uppercased()).tag($0) }
                                }
                            }
                        }
                        Section("البطولة") { leaguePicker }
                        Section {
                            Button("إظهار كل المباريات") {
                                provider = "all"; selectedLeague = LeagueFilter.all
                                liveOnly = false; search = ""; showingFilters = false
                            }
                        }
                    }.navigationTitle("تصفية المباريات").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { showingFilters = false } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .onChange(of: ntvServer) { _ in model.matches = []; model.updated = nil; selectedLeague = LeagueFilter.all }
            .fullScreenCover(item: $playback) { selected in PlayerScreen(playback: selected) }
            .alert("المشاهدة", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("حسنًا", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .alert("تحديث التطبيق", isPresented: Binding(get: { updates.notice != nil }, set: { if !$0 { updates.notice = nil } })) {
                Button("حسنًا", role: .cancel) { updates.notice = nil }
            } message: { Text(updates.notice ?? "") }

        }
    }

    private var dateStrip: some View {
        HStack(spacing: 8) {
            dateButton("أمس", offset: -1)
            dateButton("اليوم", offset: 0)
            dateButton("غدًا", offset: 1)
        }
        .accessibilityIdentifier("dayPicker")
    }

    private func dateButton(_ title: String, offset: Int) -> some View {
        let date = Site.date(offset: offset)
        let dateComponents = date.split(separator: "-")
        let number = dateComponents.last.flatMap { Int($0) } ?? 0
        return Button { day = offset } label: {
            VStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(number.formatted()).font(.title3.weight(.bold)).monospacedDigit()
            }.frame(maxWidth: .infinity, minHeight: 61)
                .foregroundStyle(day == offset ? Color.white : Color.primary)
                .background(day == offset ? colors.action : colors.card, in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).accessibilityLabel(MatchInformation.dateTitle(date))
            .accessibilityAddTraits(day == offset ? [.isSelected] : [])
    }

    private var scheduleControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { scheduleTitle; Spacer(minLength: 4); filterButtons }
            VStack(alignment: .leading, spacing: 2) { scheduleTitle; HStack(spacing: 8) { filterButtons } }
        }
    }

    private var scheduleTitle: some View {
        Text("جدول المباريات").font(.title3.bold()).fixedSize()
    }

    @ViewBuilder private var filterButtons: some View {
        Button { liveOnly.toggle() } label: {
            Label("مباشر", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.semibold)).fixedSize()
                .padding(.horizontal, 9).frame(minHeight: 44)
                .background(liveOnly ? colors.highlight : colors.card, in: Capsule())
        }.buttonStyle(.plain).foregroundStyle(liveOnly ? colors.accent : Color.primary)
            .accessibilityAddTraits(liveOnly ? [.isSelected] : [])
        Button { showingFilters = true } label: {
            Label("تصفية", systemImage: provider != "all" || selectedLeague != LeagueFilter.all
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.caption.weight(.semibold)).fixedSize()
                .padding(.horizontal, 9).frame(minHeight: 44)
                .background(colors.card, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func matchList(excluding featuredID: String?) -> some View {
        let matches = filteredMatches.filter { $0.id != featuredID }
        let grouped = Dictionary(grouping: matches) { $0.tournament.filterKey }
        var seen = Set<String>()
        let tournaments = matches.map(\.tournament).filter { seen.insert($0.filterKey).inserted }
        return ForEach(tournaments, id: \.filterKey) { tournament in
            leagueGroup(tournament, entries: grouped[tournament.filterKey, default: []])
        }
    }

    private func leagueGroup(_ league: Competition, entries: [Match]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RemoteLogo(path: league.logo, size: 23).accessibilityHidden(true)
                Text(league.name).font(.subheadline.bold())
                Spacer()
                Text("\(entries.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 13).padding(.vertical, 11)
                .background(colors.highlight.opacity(0.65))
                .accessibilityAddTraits(.isHeader)
            ForEach(entries) { match in
                Rectangle().fill(colors.divider).frame(height: 1).accessibilityHidden(true)
                MatchCard(match: match, checking: checkingMatch == match.id, anotherMatchIsOpening: checkingMatch != nil) {
                    Task { await open(match) }
                }
            }
        }.background(colors.card, in: RoundedRectangle(cornerRadius: 17))
            .clipShape(RoundedRectangle(cornerRadius: 17))
    }

    private var leaguePicker: some View {
        Menu {
            Button { selectedLeague = LeagueFilter.all; selectedLeagueTitle = "كل الدوريات" } label: {
                if selectedLeague == LeagueFilter.all { Label("إظهار الكل", systemImage: "checkmark") }
                else { Text("إظهار الكل") }
            }
            ForEach(leagues, id: \.filterKey) { league in
                Button { selectedLeague = league.filterKey; selectedLeagueTitle = league.name } label: {
                    if selectedLeague == league.filterKey { Label(league.name, systemImage: "checkmark") }
                    else { Text(league.name) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(colors.accent)
                Text(selectedLeague == LeagueFilter.all ? "كل الدوريات" : selectedLeagueTitle)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                Spacer()
                Image(systemName: "chevron.down").font(.caption.bold()).foregroundStyle(.secondary)
            }.padding(14).background(colors.card, in: RoundedRectangle(cornerRadius: 14))
        }.accessibilityLabel("اختيار الدوري")
            .accessibilityIdentifier("leaguePicker")
    }

    private var header: some View {
        FootballSectionHeader(title: "المباريات", subtitle: FootballBrand.name, icon: "soccerball") {
            Button { showingSearch.toggle(); if !showingSearch { search = "" } } label: {
                Image(systemName: showingSearch ? "xmark" : "magnifyingglass")
                    .font(.title3.weight(.medium)).frame(width: 44, height: 44)
                    .background(colors.highlight, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(showingSearch ? "إغلاق البحث" : "البحث عن مباراة")
        }
    }

    @MainActor private func open(_ match: Match) async {
        guard checkingMatch == nil else { return }
        checkingMatch = match.id
        defer { checkingMatch = nil }
        do {
            // Recheck availability on every tap; a previously published link can expire.
            let fresh: [Match]
            if match.providerID == "ntv" { fresh = try await NTVProvider.matches(date: match.date, server: ntvServer) }
            else { fresh = try await MatchesAPI().load(date: match.date) }
            guard let current = fresh.first(where: { $0.id == match.id }) else {
                message = "هذه المباراة لم تعد موجودة في الجدول الحالي."
                await model.refresh(offset: day, ntvServer: ntvServer)
                return
            }
            let sources = try await BroadcastCatalog.sources(for: current, alongside: model.matches)
            guard !sources.isEmpty else { message = "لا توجد مصادر بث متاحة لهذه المباراة حاليًا."; return }
            let title = "\(current.home_team.name) × \(current.away_team.name)"
            playback = BroadcastCatalog.playback(from: sources, title: title)
        } catch {
            message = (error as? APIError)?.errorDescription ?? "تعذّر التحقق من البث. تأكد من الإنترنت وحاول مجددًا."
        }
    }
}
