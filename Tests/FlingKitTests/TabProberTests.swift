import XCTest
@testable import FlingKit

final class TabProberTests: XCTestCase {

    private func probe(_ output: String, _ browser: Browser = .chrome) throws -> TabMedia? {
        let r = FakeRunner()
        r.stubbedOutput = output
        return try TabProber(runner: r).probe(browser)
    }

    /// Failed osascript run: refusals arrive on stderr with a non-zero exit.
    private func probeFailing(stderr: String, _ browser: Browser = .chrome) throws -> TabMedia? {
        let r = FakeRunner()
        r.stubbedStderr = stderr
        r.stubbedExitCode = 1
        return try TabProber(runner: r).probe(browser)
    }

    // MARK: snippet vocabulary (mirrors BrowserSourceTests style)

    func test_chrome_snippet_uses_execute_with_javascript_parameter() {
        let s = Browser.chrome.probeSnippet
        XCTAssertTrue(s.contains("app.execute(app.windows[0].activeTab"))
        XCTAssertTrue(s.contains("javascript:"))
        XCTAssertFalse(s.contains("doJavaScript"))
    }

    func test_safari_snippet_uses_doJavaScript_in_currentTab() {
        let s = Browser.safari.probeSnippet
        XCTAssertTrue(s.contains("app.doJavaScript("))
        XCTAssertTrue(s.contains("{in: app.windows[0].currentTab()}"))
        XCTAssertFalse(s.contains("execute("))
    }

    func test_detector_is_embedded_as_escaped_literal() {
        // The literal must be a double-quoted JS string with interior quotes
        // escaped, or the wrapper would fail to compile in the browser.
        let lit = TabProber.detectorLiteral
        XCTAssertTrue(lit.hasPrefix("\""))
        XCTAssertTrue(lit.hasSuffix("\""))
        XCTAssertTrue(lit.contains(#"\"video,audio\""#))
    }

    // MARK: main-element selection

    func test_playing_element_beats_longer_paused_one() throws {
        let media = try probe(#"""
        {"elements":[
          {"src":"https://cdn/x/trailer.mp4","time":120,"duration":600,"paused":false},
          {"src":"https://cdn/x/feature.mp4","time":0,"duration":7200,"paused":true}
        ],"manifests":[]}
        """#)
        XCTAssertEqual(media?.streamURL, "https://cdn/x/trailer.mp4")
        XCTAssertEqual(media?.resumeAt, 120)
        XCTAssertEqual(media?.duration, 600)
        XCTAssertEqual(media?.isPlaying, true)
    }

    func test_longest_duration_wins_when_all_paused() throws {
        let media = try probe(#"""
        {"elements":[
          {"src":"https://cdn/short.mp4","time":2,"duration":30,"paused":true},
          {"src":"https://cdn/long.mp4","time":900,"duration":5400,"paused":true}
        ],"manifests":[]}
        """#)
        XCTAssertEqual(media?.streamURL, "https://cdn/long.mp4")
        XCTAssertEqual(media?.resumeAt, 900)
        XCTAssertEqual(media?.isPlaying, false)
    }

    // MARK: blob / manifest fallback

    func test_blob_src_falls_back_to_latest_manifest() throws {
        let media = try probe(#"""
        {"elements":[{"src":"blob:https://site/xyz","time":42,"duration":null,"paused":false}],
         "manifests":["https://a/new.m3u8?tok=1","https://a/old.m3u8"]}
        """#)
        XCTAssertEqual(media?.streamURL, "https://a/new.m3u8?tok=1")
        XCTAssertEqual(media?.resumeAt, 42)
        XCTAssertNil(media?.duration)
    }

    func test_blob_src_with_no_manifest_gives_nil_streamURL() throws {
        let media = try probe(#"""
        {"elements":[{"src":"blob:https://site/xyz","time":42,"duration":100,"paused":false}],"manifests":[]}
        """#)
        XCTAssertNotNil(media)
        XCTAssertNil(media?.streamURL)
    }

    // MARK: audio-only

    func test_audio_only_live_stream() throws {
        let media = try probe(#"""
        {"elements":[{"src":"https://radio.example/stream.mp3","time":900,"duration":null,"paused":false}],"manifests":[]}
        """#)
        XCTAssertEqual(media?.streamURL, "https://radio.example/stream.mp3")
        XCTAssertEqual(media?.resumeAt, 900)
        XCTAssertNil(media?.duration)
        XCTAssertEqual(media?.isPlaying, true)
    }

    // MARK: no media / junk elements

    func test_no_elements_returns_nil() throws {
        XCTAssertNil(try probe(#"{"elements":[],"manifests":[]}"#))
    }

    func test_sourceless_player_shell_is_not_media() throws {
        let media = try probe(#"""
        {"elements":[{"src":"","time":0,"duration":null,"paused":true}],"manifests":[]}
        """#)
        XCTAssertNil(media)
    }

    // MARK: resume threshold

    func test_resume_under_five_seconds_is_nil() throws {
        let media = try probe(#"""
        {"elements":[{"src":"https://cdn/a.mp4","time":3,"duration":600,"paused":false}],"manifests":[]}
        """#)
        XCTAssertNil(media?.resumeAt)
    }

    // MARK: error mapping

    /// Captured live on this machine from `osascript -l JavaScript -e` with
    /// Chrome's toggle off (2026-08-28); osascript put it on stderr, exit 1.
    func test_chrome_disabled_toggle_maps_to_typed_error() {
        let err = "execution error: Error: Error: Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events. For more information: https://support.google.com/chrome/?p=applescript (12)"
        XCTAssertThrowsError(try probeFailing(stderr: err, .chrome)) { error in
            XCTAssertEqual(error as? TabProbeError, .jsFromAppleEventsDisabled(.chrome))
        }
    }

    /// Apple's documented `do JavaScript` refusal (error 8); the message names
    /// the Develop-menu toggle verbatim.
    func test_safari_disabled_toggle_maps_to_typed_error() {
        let err = "execution error: Error: Error: The 'Allow JavaScript from Apple Events' option in Safari's Develop menu must be enabled to use 'do JavaScript'. (8)"
        XCTAssertThrowsError(try probeFailing(stderr: err, .safari)) { error in
            XCTAssertEqual(error as? TabProbeError, .jsFromAppleEventsDisabled(.safari))
        }
    }

    func test_automation_denial_is_probeFailed_not_disabled() {
        let err = "execution error: Error: Error: Not authorized to send Apple events to Google Chrome. (-1743)"
        XCTAssertThrowsError(try probeFailing(stderr: err, .chrome)) { error in
            XCTAssertEqual(error as? TabProbeError, .probeFailed(err))
        }
    }

    // A page quoting the toggle's remediation text in its stdout payload must
    // not read as the toggle being off — markers only count on stderr of a
    // failed run.
    func test_toggle_text_in_page_output_of_clean_run_is_not_disabled() {
        let out = "how to fix: Allow JavaScript from Apple Events"
        XCTAssertThrowsError(try probe(out, .chrome)) { error in
            XCTAssertEqual(error as? TabProbeError, .probeFailed(out))
        }
    }

    func test_toggle_text_on_stderr_of_clean_exit_is_not_disabled() throws {
        let r = FakeRunner()
        r.stubbedOutput = #"{"elements":[],"manifests":[]}"#
        r.stubbedStderr = "warning: Allow JavaScript from Apple Events deprecated someday"
        XCTAssertNil(try TabProber(runner: r).probe(.chrome))
    }

    func test_malformed_json_throws_probeFailed() {
        XCTAssertThrowsError(try probe(#"{"elements":[{"src":"#)) { error in
            guard case .probeFailed = error as? TabProbeError else {
                return XCTFail("expected probeFailed, got \(error)")
            }
        }
    }

    func test_detector_catch_payload_throws_probeFailed() {
        XCTAssertThrowsError(try probe(#"{"error":"Error: boom"}"#)) { error in
            XCTAssertEqual(error as? TabProbeError, .probeFailed("Error: boom"))
        }
    }

    func test_no_windows_throws_probeFailed() {
        XCTAssertThrowsError(try probe(#"{"error":"no-windows"}"#, .safari)) { error in
            XCTAssertEqual(error as? TabProbeError, .probeFailed("no-windows"))
        }
    }

    func test_runner_failure_throws_probeFailed() {
        let r = FakeRunner()
        r.errorToThrow = NSError(domain: "test", code: 1)
        XCTAssertThrowsError(try TabProber(runner: r).probe(.chrome)) { error in
            guard case .probeFailed = error as? TabProbeError else {
                return XCTFail("expected probeFailed, got \(error)")
            }
        }
    }
}
