import XCTest
@testable import FlingKit

final class ProcessRunningTests: XCTestCase {

    func test_captures_stdout_and_stderr_separately_with_real_exit_code() throws {
        let result = try SystemProcessRunner()
            .run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func test_clean_run_succeeds() throws {
        let result = try SystemProcessRunner().run("/bin/echo", ["hi"], timeout: 10)
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.succeeded)
    }

    // A wedged child must be killed and reported distinctly, not block forever.
    func test_timeout_kills_a_hung_child_and_reports_it() throws {
        let started = Date()
        let result = try SystemProcessRunner().run("/bin/sleep", ["999"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        // Well under sleep's 999s: the deadline plus kill-and-reap overhead.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // Output produced before the deadline survives the kill.
    func test_timeout_preserves_partial_output() throws {
        let result = try SystemProcessRunner()
            .run("/bin/sh", ["-c", "echo early; sleep 999"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.stdout, "early\n")
    }

    func test_missing_executable_throws() {
        XCTAssertThrowsError(
            try SystemProcessRunner().run("/nonexistent-binary", [], timeout: 5))
    }

    // MARK: - protocol defaults

    /// Only implements the legacy merged-string method, like the app's
    /// preview stub; the structured default must derive from it.
    private struct LegacyRunner: ProcessRunning {
        func run(_ executable: String, _ args: [String]) throws -> String { "merged" }
    }

    func test_legacy_conformer_gets_structured_result_by_default() throws {
        let result = try LegacyRunner().run("/x", [], timeout: 5)
        XCTAssertEqual(result, ProcessResult(exitCode: 0, stdout: "merged", stderr: ""))
        XCTAssertTrue(result.succeeded)
    }

    func test_structured_conformer_gets_merged_string_by_default() throws {
        let r = FakeRunner()
        r.stubbedOutput = "out"
        r.stubbedStderr = "err"
        XCTAssertEqual(try r.run("/x", []) as String, "outerr")
    }
}
