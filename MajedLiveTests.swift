import XCTest
@testable import MajedLive

final class MajedLiveTests: XCTestCase {
    private func match(ready: Bool = true, available: Bool = true, enabled: Bool = true, url: String = "https://majed-koora.live/watch.html?id=42") throws -> Match {
        let payload: [String: Any] = [
            "id": "42", "date": "2026-09-30", "time": "19:00", "state": "upcoming",
            "home_team": ["name": "الأول"], "away_team": ["name": "الثاني"], "tournament": ["name": "البطولة"],
            "watch_ready": ready, "watch_available": available, "site_watch_enabled": enabled, "watch_url": url
        ]
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
}
