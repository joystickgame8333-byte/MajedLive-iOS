import SwiftUI

struct MatchesScreen: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.colorScheme) private var colorScheme
    private var colors: ThemeColors { ThemeColors(theme: appTheme, dark: colorScheme == .dark) }
    @StateObject private var model = ScheduleModel()
    @EnvironmentObject private var updates: AppUpdates
    @AppStorage("selectedLeague") private var selectedLeague = LeagueFilter.all
    @AppStorage("selectedLeagueTitle") private var selectedLeagueTitle = "كل الدوريات"
    @State private var showingSettings = false
    @State private var day = 0
    @State private var provider = "all"
    @State private var search = ""
    @State private var playback: Playback?
    @State private var checkingMatch: String?
    @State private var message: String?
    @Environment(\.scenePhase) private var scenePhase

    private var providerMatches: [Match] {
        model.matches.filter { provider == "all" || $0.providerID == provider }
    }
    private var filteredMatches: [Match] {
        LeagueFilter.matches(providerMatches, selected: selectedLeague).filter {
            search.isEmpty || ($0.home_team.name + " " + $0.away_team.name + " " + $0.tournament.name).localizedCaseInsensitiveContains(search)
        }
    }
    private var groups: [Competition] {
        var seen = Set<String>()
        return filteredMatches.map(\.tournament).filter { seen.insert($0.filterKey).inserted }
    }
    private var leagues: [Competition] {
        var seen = Set<String>()
        return providerMatches.map(\.tournament).filter { seen.insert($0.filterKey).inserted }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("اختيار اليوم", selection: $day) {
                        Text("اليوم").tag(0)
                        Text("غدًا").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("dayPicker")
                    SearchField(text: $search, prompt: "ابحث عن فريق أو بطولة")
                    ProviderPicker(selection: $provider, options: [("all", "الكل"), ("majed", "ماجد"), ("ntv", "NTV")])
                    leaguePicker
                    HStack {
                        Text(day == 0 ? "مباريات اليوم" : "مباريات غدًا")
                            .font(.title2.bold())
                        Spacer()
                        Text("\(filteredMatches.count) مباريات")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        VStack(spacing: 12) {
                            Label(error, systemImage: "wifi.exclamationmark")
                            Button("إعادة المحاولة") { Task { await model.refresh(offset: day) } }
                        }.font(.subheadline).padding().frame(maxWidth: .infinity)
                            .background(colors.card, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if model.loading && model.matches.isEmpty {
                        ProgressView("جاري تحميل المباريات…")
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else if filteredMatches.isEmpty && model.error == nil {
                        VStack(spacing: 14) {
                            Image(systemName: "sportscourt").font(.largeTitle).foregroundStyle(colors.accent)
                            Text(selectedLeague == LeagueFilter.all ? "لا توجد مباريات تطابق اختيارك" : "لا توجد مباريات لهذا الدوري اليوم").font(.headline)
                            Text("اسحب للأسفل لتحديث الجدول").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 55)
                    } else {
                        matchList
                    }
                    if let updated = model.updated {
                        Text("آخر تحديث: \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 12)
                    }
                }.padding(20)
            }
            .background(colors.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                header.padding(.horizontal, 20)
                    .background(colors.card.ignoresSafeArea(edges: .top))
                    .overlay(alignment: .bottom) { Rectangle().fill(colors.accent.opacity(0.12)).frame(height: 1) }
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
            .refreshable { await model.refresh(offset: day) }
            .task(id: "\(day)-\(scenePhase == .active)-\(playback == nil)") {
                guard scenePhase == .active, playback == nil else { return }
                Task { await updates.check() }
                await model.refresh(offset: day)
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    await model.refresh(offset: day)
                    Task { await updates.check() }
                }
            }
            .onChange(of: day) { _ in model.matches = []; model.updated = nil; selectedLeague = LeagueFilter.all }
            .onChange(of: provider) { _ in selectedLeague = LeagueFilter.all }
            .sheet(isPresented: $showingSettings) { SettingsScreen(updates: updates) }
            .fullScreenCover(item: $playback) { selected in PlayerScreen(playback: selected) }
            .alert("المشاهدة", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("حسنًا", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .alert("تحديث التطبيق", isPresented: Binding(get: { !showingSettings && updates.notice != nil }, set: { if !$0 { updates.notice = nil } })) {
                Button("حسنًا", role: .cancel) { updates.notice = nil }
            } message: { Text(updates.notice ?? "") }

        }
    }

    private var matchList: some View {
        LazyVStack(spacing: 16) {
            ForEach(groups, id: \.filterKey) { league in
                leagueGroup(league)
            }
        }
    }
    private func leagueGroup(_ league: Competition) -> some View {
        let entries = filteredMatches.filter { $0.tournament.filterKey == league.filterKey }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                RemoteLogo(path: league.logo, size: 24)
                Text(league.name).font(.headline)
                Spacer()
                Text("\(entries.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
            ForEach(entries) { match in
                MatchCard(match: match, checking: checkingMatch == match.id) {
                    Task { await open(match) }
                }.disabled(checkingMatch != nil)
            }
        }
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
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(colors.accent).frame(width: 40, height: 40)
                Image(systemName: "soccerball").font(.system(size: 23)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(FootballBrand.name).font(.title3.bold())
                Text("المباريات ومصادر البث").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").font(.title3).padding(10)
                    .overlay(alignment: .topTrailing) {
                        if updates.available != nil {
                            Circle().fill(colors.accent).frame(width: 8, height: 8)
                        }
                    }
            }.accessibilityLabel(updates.available == nil ? "الإعدادات" : "الإعدادات، تحديث جديد متاح")
        }.padding(.vertical, 8)
    }

    @MainActor private func open(_ match: Match) async {
        guard checkingMatch == nil else { return }
        checkingMatch = match.id
        defer { checkingMatch = nil }
        do {
            // Recheck availability on every tap; a previously published link can expire.
            let fresh: [Match]
            if match.providerID == "ntv" { fresh = try await NTVProvider.matches(date: match.date) }
            else { fresh = try await MatchesAPI().load(date: match.date) }
            guard let current = fresh.first(where: { $0.id == match.id }) else {
                message = "هذه المباراة لم تعد موجودة في الجدول الحالي."
                await model.refresh(offset: day)
                return
            }
            let sources = try await BroadcastCatalog.sources(for: current)
            guard !sources.isEmpty else { message = "لا توجد مصادر بث متاحة لهذه المباراة حاليًا."; return }
            let title = "\(current.home_team.name) × \(current.away_team.name)"
            if let source = sources.first, let server = source.servers.first {
                playback = source.playback(title: title, server: server)
            }
        } catch {
            message = (error as? APIError)?.errorDescription ?? "تعذّر التحقق من البث. تأكد من الإنترنت وحاول مجددًا."
        }
    }
}

