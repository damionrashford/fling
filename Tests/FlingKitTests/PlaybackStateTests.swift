import XCTest
@testable import FlingKit

/// Live output from the device on 2026-08-25 included a `State:` line the
/// original parser ignored, so a paused video still reported isPlaying == true.
/// Worse, AppState used isPlaying to decide the casting panel state, so pausing
/// would have knocked the panel back to idle.
final class PlaybackStateTests: XCTestCase {

    private let playing = """
    Title: Canada Is READY For A FIGHT With Bunny; Unveils NEW TARIFFS
    Time: 00:00:08 / 02:40:25 (0%)
    Remaining time: 02:40:16
    State: PLAYING
    Volume: 75
    Volume muted: False
    """

    private let paused = """
    Title: Canada Is READY For A FIGHT With Bunny; Unveils NEW TARIFFS
    Time: 00:00:24 / 02:40:25 (0%)
    State: PAUSED
    Volume: 75
    Volume muted: False
    """

    func test_parses_playing_state() {
        XCTAssertEqual(CattParser.parseStatus(playing).state, .playing)
    }

    func test_parses_paused_state() {
        XCTAssertEqual(CattParser.parseStatus(paused).state, .paused)
    }

    func test_paused_media_is_not_playing() {
        XCTAssertFalse(CattParser.parseStatus(paused).isPlaying)
    }

    func test_playing_media_is_playing() {
        XCTAssertTrue(CattParser.parseStatus(playing).isPlaying)
    }

    /// Paused is still *casting* — the panel must not fall back to idle just
    /// because playback is stopped.
    func test_paused_media_still_counts_as_having_media() {
        XCTAssertTrue(CattParser.parseStatus(paused).hasMedia)
    }

    func test_no_media_has_no_media() {
        XCTAssertFalse(CattParser.parseStatus("Volume: 55\nVolume muted: False").hasMedia)
    }

    /// Short outputs carry no State line; fall back to the title+time heuristic.
    func test_missing_state_line_falls_back_to_title_and_time() {
        let s = CattParser.parseStatus("Title: X\nTime: 00:00:10 / 00:01:00 (16%)")
        XCTAssertEqual(s.state, .unknown)
        XCTAssertTrue(s.isPlaying)
    }

    func test_buffering_counts_as_playing() {
        let s = CattParser.parseStatus("Title: X\nTime: 00:00:01 / 00:10:00\nState: BUFFERING")
        XCTAssertTrue(s.isPlaying)
    }

    func test_idle_state_is_not_playing() {
        let s = CattParser.parseStatus("Title: X\nTime: 00:00:01 / 00:10:00\nState: IDLE")
        XCTAssertFalse(s.isPlaying)
    }
}

@MainActor
final class PausedPanelStateTests: XCTestCase {

    /// The panel stays in `.casting` while paused.
    func test_paused_media_keeps_the_panel_in_casting() {
        let state = AppState(catt: CattClient(executable: "/usr/bin/catt", runner: FakeRunner()),
                             browsers: BrowserReader(runner: FakeRunner()))
        let paused = CattParser.parseStatus("""
        Title: X
        Time: 00:00:24 / 02:40:25 (0%)
        State: PAUSED
        Volume: 75
        """)
        state.apply(tab: nil, status: paused)
        XCTAssertEqual(state.panel, .casting)
    }
}

/// Captured live 2026-08-25: catt sometimes omits the Time line while playback
/// is genuinely active. Requiring elapsed made the panel drop to idle mid-play.
final class MissingTimeLineTests: XCTestCase {

    private let noTimeLine = """
    Title: Canada Is READY For A FIGHT With Bunny; Unveils NEW TARIFFS
    State: PLAYING
    Volume: 55
    Volume muted: False
    """

    func test_playing_without_a_time_line_still_has_media() {
        XCTAssertTrue(CattParser.parseStatus(noTimeLine).hasMedia)
    }

    func test_playing_without_a_time_line_is_playing() {
        XCTAssertTrue(CattParser.parseStatus(noTimeLine).isPlaying)
    }

    func test_paused_without_a_time_line_still_has_media() {
        XCTAssertTrue(CattParser.parseStatus("Title: X\nState: PAUSED").hasMedia)
    }

    func test_volume_only_output_still_has_no_media() {
        XCTAssertFalse(CattParser.parseStatus("Volume: 55\nVolume muted: False").hasMedia)
    }

    func test_idle_receiver_has_no_media() {
        XCTAssertFalse(CattParser.parseStatus("State: IDLE\nVolume: 55").hasMedia)
    }

    /// Progress must degrade gracefully rather than dividing by a nil duration.
    func test_progress_is_zero_without_timing() {
        let s = CattParser.parseStatus(noTimeLine)
        XCTAssertNil(s.elapsed)
        XCTAssertNil(s.remaining)
    }
}
