import XCTest
@testable import FlingKit

final class CattParserTests: XCTestCase {

    let liveStatus = """
    Title: Poland on NATO's frontline: Can it stop Russia without the US? | Mapped Out
    Time: 00:00:01 / 00:00:15 (11%)
    Remaining time: 00:00:13
    Volume: 59
    Volume muted: False
    """

    func test_parses_title_including_colons_and_pipes() {
        let s = CattParser.parseStatus(liveStatus)
        XCTAssertEqual(s.title, "Poland on NATO's frontline: Can it stop Russia without the US? | Mapped Out")
    }

    func test_parses_elapsed_and_duration() {
        let s = CattParser.parseStatus(liveStatus)
        XCTAssertEqual(s.elapsed, 1)
        XCTAssertEqual(s.duration, 15)
    }

    func test_parses_volume() {
        XCTAssertEqual(CattParser.parseStatus(liveStatus).volume, 59)
    }

    func test_parses_muted_false() {
        XCTAssertFalse(CattParser.parseStatus(liveStatus).muted)
    }

    func test_parses_muted_true() {
        XCTAssertTrue(CattParser.parseStatus("Volume muted: True").muted)
    }

    func test_parses_hours_in_timestamps() {
        let s = CattParser.parseStatus("Time: 01:02:03 / 02:00:00 (51%)")
        XCTAssertEqual(s.elapsed, 3723)
        XCTAssertEqual(s.duration, 7200)
    }

    // Volume-only output is what catt prints when nothing is playing.
    func test_volume_only_output_has_no_title() {
        let s = CattParser.parseStatus("Volume: 30\nVolume muted: False")
        XCTAssertNil(s.title)
        XCTAssertEqual(s.volume, 30)
        XCTAssertFalse(s.isPlaying)
    }

    func test_isPlaying_true_when_title_and_time_present() {
        XCTAssertTrue(CattParser.parseStatus(liveStatus).isPlaying)
    }

    func test_parses_scan_line() {
        let devices = CattParser.parseScan("Scanning Chromecasts...\n192.168.1.42 - Living room TV - TCL Smart TV")
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].ip, "192.168.1.42")
        XCTAssertEqual(devices[0].name, "Living room TV")
        XCTAssertEqual(devices[0].model, "TCL Smart TV")
    }

    func test_scan_ignores_header_and_blank_lines() {
        XCTAssertTrue(CattParser.parseScan("Scanning Chromecasts...\n\n").isEmpty)
    }

    // A device name containing " - " must not be truncated.
    func test_scan_handles_hyphenated_device_name() {
        let devices = CattParser.parseScan("10.0.0.5 - Kitchen - Back - Nest Hub")
        XCTAssertEqual(devices[0].ip, "10.0.0.5")
        XCTAssertEqual(devices[0].name, "Kitchen - Back")
        XCTAssertEqual(devices[0].model, "Nest Hub")
    }

    func test_parses_error_line() {
        XCTAssertEqual(CattParser.parseError("Error: Nothing is currently playing."),
                       "Nothing is currently playing.")
    }

    func test_parses_receiver_timeout_as_error() {
        let out = "pychromecast.error.RequestTimeout: Execution of start app 233637DE timed out after 10.0 s."
        XCTAssertEqual(CattParser.parseError(out), "The TV did not respond. Make sure it is awake, then try again.")
    }

    func test_no_error_returns_nil() {
        XCTAssertNil(CattParser.parseError(liveStatus))
    }

    // MARK: - structured error detection

    func test_timed_out_inside_a_title_is_not_an_error() {
        XCTAssertNil(CattParser.parseError(
            "Title: why my build timed out\nTime: 00:00:01 / 00:00:15 (11%)"))
    }

    func test_requesttimeout_inside_a_title_is_not_an_error() {
        XCTAssertNil(CattParser.parseError("Title: debugging pychromecast RequestTimeout"))
    }

    func test_timeout_marker_on_a_non_title_line_still_registers() {
        let out = "Title: some video\npychromecast.error.RequestTimeout: connect timed out"
        XCTAssertEqual(CattParser.parseError(out),
                       "The TV did not respond. Make sure it is awake, then try again.")
    }

    func test_timeout_marker_on_stderr_registers() {
        XCTAssertEqual(
            CattParser.parseError(stdout: "", stderr: "socket.timeout: timed out", exitCode: 1),
            "The TV did not respond. Make sure it is awake, then try again.")
    }

    func test_error_line_on_stderr_registers() {
        XCTAssertEqual(
            CattParser.parseError(stdout: "", stderr: "Error: No device found.", exitCode: 1),
            "No device found.")
    }

    func test_nonzero_exit_without_message_falls_back_to_last_stderr_line() {
        XCTAssertEqual(
            CattParser.parseError(stdout: "", stderr: "Traceback:\nSomeException", exitCode: 2),
            "SomeException")
    }

    func test_nonzero_exit_with_empty_stderr_gets_generic_message() {
        XCTAssertEqual(CattParser.parseError(stdout: "", stderr: "", exitCode: 2),
                       "catt failed (exit 2)")
    }

    func test_clean_structured_run_returns_nil() {
        XCTAssertNil(CattParser.parseError(stdout: liveStatus, stderr: "", exitCode: 0))
    }
}
