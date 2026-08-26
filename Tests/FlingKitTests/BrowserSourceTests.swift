import XCTest
@testable import FlingKit

final class BrowserSourceTests: XCTestCase {

    func test_chrome_snippet_uses_activeTab_and_title() {
        let s = Browser.chrome.tabSnippet
        XCTAssertTrue(s.contains("activeTab"))
        XCTAssertTrue(s.contains(".title()"))
        XCTAssertFalse(s.contains("currentTab"))
    }

    func test_safari_snippet_uses_currentTab_and_name() {
        let s = Browser.safari.tabSnippet
        XCTAssertTrue(s.contains("currentTab"))
        XCTAssertTrue(s.contains(".name()"))
        XCTAssertFalse(s.contains("activeTab"))
    }

    func test_process_names_match_the_real_applications() {
        XCTAssertEqual(Browser.chrome.processName, "Google Chrome")
        XCTAssertEqual(Browser.safari.processName, "Safari")
    }

    func test_readTab_parses_json_payload() throws {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://youtu.be/a","title":"A Video"}"#
        let tab = try BrowserReader(runner: r).readTab(.chrome)
        XCTAssertEqual(tab.url, "https://youtu.be/a")
        XCTAssertEqual(tab.title, "A Video")
        XCTAssertEqual(tab.browser, .chrome)
        XCTAssertEqual(tab.kind, .youtube)
    }

    func test_readTab_with_no_windows_throws_typed_error() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"error":"no-windows"}"#
        XCTAssertThrowsError(try BrowserReader(runner: r).readTab(.safari)) { error in
            XCTAssertEqual(error as? BrowserError, .noWindows(.safari))
        }
    }

    func test_readTab_with_permission_denial_throws_typed_error() {
        let r = FakeRunner()
        r.stubbedOutput = "execution error: Not authorized to send Apple events to Safari. (-1743)"
        XCTAssertThrowsError(try BrowserReader(runner: r).readTab(.safari)) { error in
            XCTAssertEqual(error as? BrowserError, .permissionDenied(.safari))
        }
    }

    func test_blank_tab_url_classifies_as_not_castable() throws {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"","title":""}"#
        let tab = try BrowserReader(runner: r).readTab(.chrome)
        XCTAssertFalse(tab.kind.isCastable)
    }

    func test_isRunning_true_when_system_events_reports_a_process() {
        let r = FakeRunner()
        r.stubbedOutput = "true"
        XCTAssertTrue(BrowserReader(runner: r).isRunning(.chrome))
    }

    func test_isRunning_false_when_system_events_reports_none() {
        let r = FakeRunner()
        r.stubbedOutput = "false"
        XCTAssertFalse(BrowserReader(runner: r).isRunning(.chrome))
    }
}
