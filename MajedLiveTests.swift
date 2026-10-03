import XCTest
@testable import MajedLive

final class MajedLiveTests: XCTestCase {
    private func match(ready: Bool = true, available: Bool = true, enabled: Bool = true, url: String = "https://majed-koora.live/watch.html?id=42", state: String = "upcoming", elapsed: Int? = nil, syncedAt: Double? = nil, leagueID: String = "cup1", homeScore: Int? = nil, awayScore: Int? = nil, broadcast: [String: Any]? = nil, stadium: String? = nil, round: String? = nil) throws -> Match {
        var payload: [String: Any] = [
            "id": "42", "date": "2026-09-30", "time": "19:00", "state": state,
            "home_team": ["name": "الأول"], "away_team": ["name": "الثاني"], "tournament": ["id": leagueID, "name": "البطولة"],
            "watch_ready": ready, "watch_available": available, "site_watch_enabled": enabled, "watch_url": url
        ]
        if let elapsed { payload["elapsed_seconds"] = elapsed }
        if let syncedAt { payload["clock_synced_at"] = syncedAt }
        if let homeScore { payload["home_team"] = ["name": "الأول", "score": homeScore] }
        if let awayScore { payload["away_team"] = ["name": "الثاني", "score": awayScore] }
        if let broadcast { payload["broadcast"] = broadcast }
        if let stadium { payload["stadium"] = stadium }
        if let round { payload["round"] = round }
        return try JSONDecoder().decode(Match.self, from: JSONSerialization.data(withJSONObject: payload))
    }
    func testPublishedMatchInformationAndMissingMetadataDoNotChangePlaybackAvailability() throws {
        let published = try match(broadcast: ["channel": "  قناة رياضية 1، قناة رياضية 2  ", "commentator": "المعلق"],
                                  stadium: " الملعب ", round: "الجولة 3")
        XCTAssertEqual(published.broadcastChannel, "قناة رياضية 1، قناة رياضية 2")
        XCTAssertEqual(published.commentatorName, "المعلق")
        XCTAssertEqual(published.stadiumName, "الملعب")
        XCTAssertEqual(published.roundTitle, "الجولة 3")
        XCTAssertNotNil(published.playbackURL)
        for missing in [try match(), try match(broadcast: ["channel": " \n ", "commentator": NSNull()], stadium: "", round: " ")] {
            XCTAssertNil(missing.broadcastChannel)
            XCTAssertNil(missing.commentatorName)
            XCTAssertNil(missing.stadiumName)
            XCTAssertNil(missing.roundTitle)
            XCTAssertNotNil(missing.playbackURL)
        }
        XCTAssertNil(try match(ready: false, broadcast: ["channel": "القناة"]).playbackURL)
    }

    func testNoPublishedBroadcastHasNoPlayerURL() throws {
        XCTAssertNil(try match(ready: false, available: false, url: "").playbackURL)
    }
    func testAllWebsiteAvailabilityConditionsAreRequired() throws {
        XCTAssertNotNil(try match().playbackURL)
        XCTAssertNil(try match(ready: false).playbackURL)
        XCTAssertNil(try match(available: false).playbackURL)
        XCTAssertNil(try match(enabled: false).playbackURL)
    }
    func testUnsafeAndRelativePlayerLinksAreRejected() throws {
        for url in ["http://example.com/watch", "javascript:alert(1)", "/watch", "https://user:password@example.com/watch", "https://"] {
            XCTAssertNil(try match(url: url).playbackURL)
        }
    }
    func testRiyadhDayRolloverAndTomorrow() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-30T21:15:00Z"))
        XCTAssertEqual(Site.date(offset: 0, now: now), "2026-10-01")
        XCTAssertEqual(Site.date(offset: 1, now: now), "2026-10-02")
    }
    func testWebsiteImagePathsAreResolved() {
        XCTAssertEqual(Site.media("/media/teams/logo.png")?.absoluteString, "https://majed-koora.live/media/teams/logo.png")
        XCTAssertNil(Site.media(""))
    }
    func testLiveClockUsesPublishedSyncAndStopsAtHalftime() throws {
        let now = Date(timeIntervalSince1970: 110)
        XCTAssertEqual(try match(state: "live", elapsed: 3590, syncedAt: 100000).clockText(now: now), "60:00")
        XCTAssertEqual(try match(state: "halftime", elapsed: 3590, syncedAt: 100000).clockText(now: now), "59:50")
        XCTAssertEqual(try match(state: "live", elapsed: 3590, syncedAt: 120000).clockText(now: now), "59:50")
        XCTAssertNil(try match(state: "live").clockText(now: now))
        XCTAssertNil(try match(elapsed: 0).clockText(now: now))
    }
    func testLeagueFilterUsesIDsAndSupportsAllAndEmptyDays() throws {
        let first = try match(leagueID: "cup1")
        let second = try match(leagueID: "cup2")
        XCTAssertEqual(LeagueFilter.matches([first, second], selected: LeagueFilter.all).count, 2)
        XCTAssertEqual(LeagueFilter.matches([first, second], selected: "id:cup1").count, 1)
        XCTAssertEqual(LeagueFilter.matches([second], selected: "id:cup1").count, 0)
    }
    func testScoresPreserveRealGoalsAndDoNotInventMissingGoals() throws {
        XCTAssertEqual(try match(state: "live", homeScore: 0, awayScore: 4).scoreText, "0 : 4")
        XCTAssertEqual(try match(state: "live").scoreText, "— : —")
    }
    func testNativeHLSSelects720WithoutInvalidMasterGroups() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:RESOLUTION=1920x1080,VIDEO="missing",CODECS="avc1.64002A,mp4a.40.2"
        high.css?sig=keep-high
        #EXT-X-STREAM-INF:RESOLUTION=1280x720,VIDEO="missing"
        medium.css?sig=keep-medium
        #EXT-X-STREAM-INF:RESOLUTION=852x480
        low.css?sig=keep-low
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/live/master.css?sig=master"))
        XCTAssertEqual(HLSPlaylist.compatibleVariant(master, base: base).absoluteString,
                       "https://example.com/live/medium.css?sig=keep-medium")
        XCTAssertEqual(HLSPlaylist.compatibleVariant("#EXTM3U\n#EXTINF:2\nsegment.ts", base: base), base)
    }
    func testHLSAdapterPreservesSignedSegmentAndKeyURLs() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/live/variant.css"))
        let playlist = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin?sig=key\"\n#EXTINF:2\nsegment.png?sig=segment\n"
        var mapped: [URL] = []
        let output = HLSPlaylist.rewrite(playlist, base: base) { url in
            mapped.append(url)
            return URL(string: "http://localhost:12345/\(mapped.count)/media")!
        }
        XCTAssertEqual(mapped.map(\.absoluteString), ["https://example.com/live/key.bin?sig=key", "https://example.com/live/segment.png?sig=segment"])
        XCTAssertTrue(output.contains("METHOD=AES-128,URI=\"http://localhost:12345/1/media\""))
        XCTAssertTrue(output.contains("http://localhost:12345/2/media"))
    }

    func testNativeMediaByteRanges() {
        XCTAssertEqual(HLSPlaylist.byteRange("bytes=0-1", count: 10), 0..<2)
        XCTAssertEqual(HLSPlaylist.byteRange("bytes=3-", count: 10), 3..<10)
        XCTAssertEqual(HLSPlaylist.byteRange("bytes=-4", count: 10), 6..<10)
        XCTAssertEqual(HLSPlaylist.byteRange("bytes=8-99", count: 10), 8..<10)
        XCTAssertNil(HLSPlaylist.byteRange("bytes=10-", count: 10))
        XCTAssertNil(HLSPlaylist.byteRange("bytes=4-2", count: 10))
        XCTAssertNil(HLSPlaylist.byteRange("bytes=0-1,4-5", count: 10))
        XCTAssertNil(HLSPlaylist.byteRange("bytes=0-", count: 0))
    }

    func testBroadcastChoiceKeepsProviderContextAndChosenServer() throws {
        let first = StreamServer(id: "one", name: "Server 1", type: "iframe", url: "https://example.com/one", enabled: true, is_default: true, priority: 0)
        let chosen = StreamServer(id: "two", name: "Server 2", type: "m3u8", url: "https://example.com/two.m3u8", enabled: true, is_default: false, priority: 1)
        let watch = try XCTUnwrap(URL(string: "https://example.com/watch"))
        let source = BroadcastSource(id: "provider", name: "Provider", watchURL: watch, servers: [first, chosen])
        let playback = source.playback(title: "Match", server: chosen)
        XCTAssertEqual(playback.initialServerID, "two")
        XCTAssertEqual(playback.url, watch)
        XCTAssertEqual(playback.providerName, "Provider")
        XCTAssertEqual(playback.servers.count, 2)
    }

    func testUpdateAlertsRequirePublishedIPAAndSkipInstalledOrAlreadyNotifiedBuilds() throws {
        func release(build: String = "build-20", draft: Bool = false,
                     prerelease: Bool = false, assets: Bool = true,
                     url: String = "https://github.com/joystickgame8333-byte/MajedLive-iOS/releases/download/build-20/MajedLive.ipa") throws -> AppRelease {
            let payload: [String: Any] = [
                "tag_name": build, "draft": draft, "prerelease": prerelease,
                "assets": assets ? [["name": "MajedLive.ipa", "browser_download_url": url]] : []
            ]
            return try JSONDecoder().decode(AppRelease.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let published = try release()
        XCTAssertEqual(UpdateNotificationPolicy.newBuild(published, installed: 19, notified: 18), 20)
        XCTAssertNil(UpdateNotificationPolicy.newBuild(published, installed: 20, notified: 18))
        XCTAssertNil(UpdateNotificationPolicy.newBuild(published, installed: 21, notified: 18))
        XCTAssertNil(UpdateNotificationPolicy.newBuild(published, installed: 19, notified: 20))
        XCTAssertNil(UpdateNotificationPolicy.newBuild(published, installed: 19, notified: 21))
        for invalid in [try release(draft: true), try release(prerelease: true), try release(assets: false),
                        try release(build: "preview-20"),
                        try release(url: "https://github.com/other/repo/releases/download/build-20/MajedLive.ipa")] {
            XCTAssertNil(UpdateNotificationPolicy.newBuild(invalid, installed: 19, notified: 18))
        }
    }

    func testFajrSourcesKeepFreshPublishedSignaturesAndRejectUnsafeURLs() {
        let html = #"src: "https://vstream6.hadara.ps:8443/live/playlist.m3u8?sig=fresh&amp;id=1", src: "http://vstream6.hadara.ps/live/playlist.m3u8", src: "https://other.example/live/playlist.m3u8", src: "https://vstream6.hadara.ps:8443/live/playlist.m3u8?sig=fresh&amp;id=1""#
        let sources = FajrStream.candidates(html: html)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.query, "sig=fresh&id=1")
        XCTAssertTrue(ChannelCatalog.channels.allSatisfy { $0.playback != nil })
        XCTAssertEqual(Set(ChannelCatalog.channels.flatMap { $0.source.servers.map(\.id) }).count, 9)
    }

}
