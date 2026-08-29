import XCTest
@testable import FlingKit

/// Requires real browsers. Skips rather than fails when one is not running,
/// so it proves nothing unless run manually with both browsers open.
final class LiveBrowserTests: XCTestCase {

    func test_live_chrome_tab_read() throws {
        try readAndReport(.chrome)
    }

    func test_live_safari_tab_read() throws {
        try readAndReport(.safari)
    }

    /// Running with no windows is a state the app handles, so skip it; any
    /// other error is let through so a real regression still fails.
    private func readAndReport(_ browser: Browser) throws {
        let reader = BrowserReader()
        try XCTSkipUnless(reader.isRunning(browser), "\(browser.displayName) not running")
        do {
            let tab = try reader.readTab(browser)
            XCTAssertFalse(tab.url.isEmpty)
            print("\(browser.displayName) → \(tab.url) | \(tab.title)")
        } catch BrowserError.noWindows {
            throw XCTSkip("\(browser.displayName) is running with no windows open")
        }
    }
}
