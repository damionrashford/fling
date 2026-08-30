import XCTest
@testable import FlingKit

final class PermissionProbeTests: XCTestCase {

    /// Fresh cache per probe so tests never see another test's grants.
    private func probe(_ runner: FakeRunner, installed: [Browser]) -> PermissionProbe {
        PermissionProbe(runner: runner, installed: installed,
                        cache: PermissionProbe.GrantCache())
    }

    private func denyAll(_ r: FakeRunner) {
        r.stubbedStderr = "execution error: Not authorized to send Apple events to Safari. (-1743)"
        r.stubbedExitCode = 1
    }

    func test_reports_browser_as_missing_when_permission_denied() {
        let r = FakeRunner()
        denyAll(r)
        XCTAssertEqual(probe(r, installed: [.safari]).missingGrants(), [.safari])
    }

    func test_reports_nothing_missing_when_read_succeeds() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://a.com","title":"A"}"#
        XCTAssertTrue(probe(r, installed: [.chrome]).missingGrants().isEmpty)
    }

    // A browser with no windows is a granted browser — the read got through.
    func test_no_windows_is_not_a_missing_grant() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"error":"no-windows"}"#
        XCTAssertTrue(probe(r, installed: [.chrome]).missingGrants().isEmpty)
    }

    // A page about the -1743 error is content, not a denial; only stderr of a
    // failed run counts.
    func test_page_content_mentioning_denial_is_not_a_missing_grant() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://a.com/q","title":"Not authorized to send Apple events (-1743)"}"#
        XCTAssertTrue(probe(r, installed: [.safari]).missingGrants().isEmpty)
    }

    func test_only_probes_installed_browsers() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://a.com","title":"A"}"#
        _ = probe(r, installed: [.chrome]).missingGrants()
        XCTAssertEqual(r.calls.count, 1)
    }

    func test_probes_every_installed_browser() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://a.com","title":"A"}"#
        _ = probe(r, installed: [.chrome, .safari]).missingGrants()
        XCTAssertEqual(r.calls.count, 2)
    }

    func test_missing_list_preserves_declaration_order() {
        let r = FakeRunner()
        denyAll(r)
        XCTAssertEqual(probe(r, installed: [.safari, .chrome]).missingGrants(),
                       [.safari, .chrome])
    }

    // MARK: - grant caching

    // Grants are effectively never revoked mid-session, so a successful probe
    // must not spawn osascript again on the next panel open.
    func test_granted_result_is_cached_for_the_cache_lifetime() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://a.com","title":"A"}"#
        let p = probe(r, installed: [.chrome])
        XCTAssertTrue(p.missingGrants().isEmpty)
        XCTAssertTrue(p.missingGrants().isEmpty)
        XCTAssertEqual(r.calls.count, 1)
    }

    // A denial must re-probe: the user may grant consent between panel opens.
    func test_denial_is_not_cached() {
        let r = FakeRunner()
        denyAll(r)
        let p = probe(r, installed: [.chrome])
        XCTAssertEqual(p.missingGrants(), [.chrome])
        XCTAssertEqual(p.missingGrants(), [.chrome])
        XCTAssertEqual(r.calls.count, 2)
    }

    func test_grant_after_denial_is_noticed_then_cached() {
        let r = FakeRunner()
        denyAll(r)
        let p = probe(r, installed: [.chrome])
        XCTAssertEqual(p.missingGrants(), [.chrome])

        r.stubbedStderr = ""
        r.stubbedExitCode = 0
        r.stubbedOutput = #"{"url":"https://a.com","title":"A"}"#
        XCTAssertTrue(p.missingGrants().isEmpty)
        XCTAssertTrue(p.missingGrants().isEmpty)
        XCTAssertEqual(r.calls.count, 2)
    }
}
