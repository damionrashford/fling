import XCTest
@testable import FlingKit

/// Shared fake used by CattClient, BrowserSource, AppState, and PermissionProbe tests.
/// `@unchecked Sendable` because AppState hands its client to detached tasks;
/// tests drive it sequentially and read `calls` only after awaiting.
final class FakeRunner: ProcessRunning, @unchecked Sendable {
    var calls: [(exe: String, args: [String])] = []
    var stubbedOutput = ""
    var errorToThrow: Error?

    func run(_ executable: String, _ args: [String]) throws -> String {
        calls.append((executable, args))
        if let errorToThrow { throw errorToThrow }
        return stubbedOutput
    }
}

final class CattClientTests: XCTestCase {

    private func client(_ runner: FakeRunner) -> CattClient {
        CattClient(executable: "/usr/bin/catt", runner: runner)
    }

    func test_scan_returns_devices() throws {
        let r = FakeRunner()
        r.stubbedOutput = "Scanning Chromecasts...\n192.168.1.42 - Living room TV - TCL Smart TV"
        let devices = try client(r).scan()
        XCTAssertEqual(devices, [DeviceInfo(ip: "192.168.1.42", name: "Living room TV", model: "TCL Smart TV")])
        XCTAssertEqual(r.calls[0].args, ["scan"])
    }

    // The -f flag is load-bearing: without it catt pipes the URL through yt-dlp,
    // which 403s on plain .mp4 files. Observed live 2026-08-25.
    func test_direct_media_uses_force_default_flag() throws {
        let r = FakeRunner()
        try client(r).cast("https://ex.com/a.mp4", kind: .directMedia, device: "Living room TV")
        XCTAssertEqual(r.calls[0].args, ["-d", "Living room TV", "cast", "-f", "https://ex.com/a.mp4"])
    }

    func test_youtube_does_not_use_force_default_flag() throws {
        let r = FakeRunner()
        try client(r).cast("https://youtu.be/abc", kind: .youtube, device: "Living room TV")
        XCTAssertEqual(r.calls[0].args, ["-d", "Living room TV", "cast", "https://youtu.be/abc"])
    }

    func test_extractable_site_does_not_use_force_default_flag() throws {
        let r = FakeRunner()
        try client(r).cast("https://vimeo.com/1", kind: .extractableSite, device: "TV")
        XCTAssertEqual(r.calls[0].args, ["-d", "TV", "cast", "https://vimeo.com/1"])
    }

    func test_casting_a_non_castable_url_throws_without_running_anything() {
        let r = FakeRunner()
        XCTAssertThrowsError(
            try client(r).cast("https://news.ycombinator.com",
                               kind: .notCastable(reason: "Not a video page"),
                               device: "TV")
        )
        XCTAssertTrue(r.calls.isEmpty)
    }

    func test_setVolume_clamps_above_range() throws {
        let r = FakeRunner()
        try client(r).setVolume(140, device: "TV")
        XCTAssertEqual(r.calls[0].args, ["-d", "TV", "volume", "100"])
    }

    func test_setVolume_clamps_below_range() throws {
        let r = FakeRunner()
        try client(r).setVolume(-5, device: "TV")
        XCTAssertEqual(r.calls[0].args, ["-d", "TV", "volume", "0"])
    }

    func test_seek_forward_uses_ffwd() throws {
        let r = FakeRunner()
        try client(r).seek(by: 30, device: "TV")
        XCTAssertEqual(r.calls[0].args, ["-d", "TV", "ffwd", "30"])
    }

    func test_seek_backward_uses_rewind_with_positive_magnitude() throws {
        let r = FakeRunner()
        try client(r).seek(by: -30, device: "TV")
        XCTAssertEqual(r.calls[0].args, ["-d", "TV", "rewind", "30"])
    }

    func test_status_parses_output() throws {
        let r = FakeRunner()
        r.stubbedOutput = "Title: X\nTime: 00:00:10 / 00:01:00 (16%)\nVolume: 40\nVolume muted: False"
        let s = try client(r).status(device: "TV")
        XCTAssertEqual(s.title, "X")
        XCTAssertEqual(s.volume, 40)
    }

    // catt exits 0 while printing an error, so stdout must be inspected too.
    func test_error_in_stdout_is_surfaced_as_thrown_error() {
        let r = FakeRunner()
        r.stubbedOutput = "Error: Nothing is currently playing."
        XCTAssertThrowsError(try client(r).pause(device: "TV")) { error in
            XCTAssertEqual((error as? CattError)?.message, "Nothing is currently playing.")
        }
    }

    func test_receiver_timeout_gets_human_message() {
        let r = FakeRunner()
        r.stubbedOutput = "pychromecast.error.RequestTimeout: Execution of start app 233637DE timed out after 10.0 s."
        XCTAssertThrowsError(try client(r).cast("https://youtu.be/a", kind: .youtube, device: "TV")) { error in
            XCTAssertEqual((error as? CattError)?.message,
                           "The TV did not respond. Make sure it is awake, then try again.")
        }
    }
}
