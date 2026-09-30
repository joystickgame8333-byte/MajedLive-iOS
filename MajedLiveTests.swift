import XCTest
@testable import MajedLive

final class MajedLiveTests: XCTestCase {
    private func match(ready: Bool = true, available: Bool = true, enabled: Bool = true, url: String = "https://majed-koora.live/watch.html?id=42", state: String = "upcoming", elapsed: Int? = nil, syncedAt: Double? = nil, leagueID: String = "cup1", homeScore: Int? = nil, awayScore: Int? = nil) throws -> Match {
        var payload: [String: Any] = [
            "id": "42", "date": "2026-09-30", "time": "19:00", "state": state,
            "home_team": ["name": "الأول"], "away_team": ["name": "الثاني"], "tournament": ["id": leagueID, "name": "البطولة"],
            "watch_ready": ready, "watch_available": available, "site_watch_enabled": enabled, "watch_url": url
        ]
        if let elapsed { payload["elapsed_seconds"] = elapsed }
        if let syncedAt { payload["clock_synced_at"] = syncedAt }
        if let homeScore { payload["home_team"] = ["name": "الأول", "score": homeScore] }
        if let awayScore { payload["away_team"] = ["name": "الثاني", "score": awayScore] }
        return try JSONDecoder().decode(Match.self, from: JSONSerialization.data(withJSONObject: payload))
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

}
