import XCTest
@testable import FlingKit

final class PermissionProbeTests: XCTestCase {

    func test_reports_browser_as_missing_when_permission_denied() {
        let r = FakeRunner()
        r.stubbedOutput = "execution error: Not authorized to send Apple events to Safari. (-1743)"
        let probe = PermissionProbe(runner: r, installed: [.safari])
        XCTAssertEqual(probe.missingGrants(), [.safari])
    }

    func test_reports_nothing_missing_when_read_succeeds() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://a.com","title":"A"}"#
        let probe = PermissionProbe(runner: r, installed: [.chrome])
        XCTAssertTrue(probe.missingGrants().isEmpty)
    }

    // A browser with no windows is a granted browser — the read got through.
    func test_no_windows_is_not_a_missing_grant() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"error":"no-windows"}"#
        let probe = PermissionProbe(runner: r, installed: [.chrome])
        XCTAssertTrue(probe.missingGrants().isEmpty)
    }

    func test_only_probes_installed_browsers() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://a.com","title":"A"}"#
        _ = PermissionProbe(runner: r, installed: [.chrome]).missingGrants()
        XCTAssertEqual(r.calls.count, 1)
    }

    func test_probes_every_installed_browser() {
        let r = FakeRunner()
        r.stubbedOutput = #"{"url":"https://a.com","title":"A"}"#
        _ = PermissionProbe(runner: r, installed: [.chrome, .safari]).missingGrants()
        XCTAssertEqual(r.calls.count, 2)
    }

    func test_missing_list_preserves_declaration_order() {
        let r = FakeRunner()
        r.stubbedOutput = "execution error: Not authorized to send Apple events. (-1743)"
        let probe = PermissionProbe(runner: r, installed: [.safari, .chrome])
        XCTAssertEqual(probe.missingGrants(), [.safari, .chrome])
    }
}
