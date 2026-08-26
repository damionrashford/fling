import XCTest
@testable import FlingKit

/// Requires real browsers. Skips rather than fails when one is not running,
/// so the suite stays green in CI, but MUST be run manually with both open.
final class LiveBrowserTests: XCTestCase {

    func test_live_chrome_tab_read() throws {
        let reader = BrowserReader()
        try XCTSkipUnless(reader.isRunning(.chrome), "Chrome not running")
        let tab = try reader.readTab(.chrome)
        XCTAssertFalse(tab.url.isEmpty)
        print("Chrome → \(tab.url) | \(tab.title)")
    }

    func test_live_safari_tab_read() throws {
        let reader = BrowserReader()
        try XCTSkipUnless(reader.isRunning(.safari), "Safari not running")
        let tab = try reader.readTab(.safari)
        XCTAssertFalse(tab.url.isEmpty)
        print("Safari → \(tab.url) | \(tab.title)")
    }
}
