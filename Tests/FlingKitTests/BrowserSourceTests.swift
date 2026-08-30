import XCTest
@testable import FlingKit

/// Shared fake for the NSWorkspace seam.
struct FakeApps: RunningAppsReading {
    var running: Set<String> = []
    var frontmost: String?
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func frontmostBundleID() -> String? { frontmost }
}

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

    // osascript reports denial on stderr and exits non-zero.
    func test_readTab_with_permission_denial_throws_typed_error() {
        let r = FakeRunner()
        r.stubbedStderr = "execution error: Not authorized to send Apple events to Safari. (-1743)"
        r.stubbedExitCode = 1
        XCTAssertThrowsError(try BrowserReader(runner: r).readTab(.safari)) { error in
            XCTAssertEqual(error as? BrowserError, .permissionDenied(.safari))
        }
    }

    // A page *about* the automation error must not trip the permission sniff:
    // only stderr of a failed run counts.
    func test_readTab_ignores_permission_text_inside_page_content() throws {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://apple.stackexchange.com/q/1","title":"Fix: Not authorized to send Apple events (-1743)"}"#
        let tab = try BrowserReader(runner: r).readTab(.safari)
        XCTAssertEqual(tab.title, "Fix: Not authorized to send Apple events (-1743)")
    }

    func test_readTab_failed_run_without_denial_is_unreadable() {
        let r = FakeRunner()
        r.stubbedStderr = "execution error: some other failure (12)"
        r.stubbedExitCode = 1
        XCTAssertThrowsError(try BrowserReader(runner: r).readTab(.chrome)) { error in
            XCTAssertEqual(error as? BrowserError,
                           .unreadable(.chrome, "execution error: some other failure (12)"))
        }
    }

    func test_blank_tab_url_classifies_as_not_castable() throws {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"","title":""}"#
        let tab = try BrowserReader(runner: r).readTab(.chrome)
        XCTAssertFalse(tab.kind.isCastable)
    }

    // MARK: - NSWorkspace-backed liveness (no subprocess spawns)

    func test_isRunning_true_when_workspace_lists_the_bundle_id() {
        let apps = FakeApps(running: ["com.google.Chrome"])
        XCTAssertTrue(BrowserReader(runner: FakeRunner(), apps: apps).isRunning(.chrome))
    }

    func test_isRunning_false_when_workspace_does_not_list_it() {
        let apps = FakeApps(running: ["com.apple.Safari"])
        XCTAssertFalse(BrowserReader(runner: FakeRunner(), apps: apps).isRunning(.chrome))
    }

    func test_isRunning_and_frontmostApp_spawn_no_subprocess() {
        let r = FakeRunner()
        let reader = BrowserReader(runner: r, apps: FakeApps(running: ["com.google.Chrome"],
                                                             frontmost: "com.google.Chrome"))
        _ = reader.isRunning(.chrome)
        _ = reader.isRunning(.safari)
        _ = reader.frontmostApp()
        XCTAssertTrue(r.calls.isEmpty)
    }

    /// The resolver matches on process names, so the bundle id maps back to one.
    func test_frontmostApp_maps_browser_bundle_id_to_process_name() {
        let apps = FakeApps(frontmost: "com.apple.Safari")
        XCTAssertEqual(BrowserReader(runner: FakeRunner(), apps: apps).frontmostApp(), "Safari")
    }

    // A non-browser frontmost app never matches anything in the resolver, so
    // nil preserves the old semantics.
    func test_frontmostApp_is_nil_for_non_browser_app() {
        let apps = FakeApps(frontmost: "com.apple.dt.Xcode")
        XCTAssertNil(BrowserReader(runner: FakeRunner(), apps: apps).frontmostApp())
    }
}
