import XCTest
@testable import FlingKit

/// Requires real browsers. Skips rather than fails when one is not running,
/// so the suite stays green in CI, but MUST be run manually with both open.
final class LiveBrowserTests: XCTestCase {

    func test_live_chrome_tab_read() throws {
        try readAndReport(.chrome)
    }

    func test_live_safari_tab_read() throws {
        try readAndReport(.safari)
    }

    /// A browser that is running with no windows is a valid state the app
    /// handles, not a test failure — skip it rather than reporting red, but
    /// let any other error through so a real regression still fails loudly.
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
