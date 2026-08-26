import XCTest
@testable import FlingKit

@MainActor
final class AppStateTests: XCTestCase {

    private func makeState(_ runner: FakeRunner) -> AppState {
        AppState(catt: CattClient(executable: "/usr/bin/catt", runner: runner),
                 browsers: BrowserReader(runner: runner))
    }

    func test_starts_in_setup_when_catt_is_missing() {
        let state = AppState(catt: nil, browsers: BrowserReader(runner: FakeRunner()))
        XCTAssertEqual(state.panel, .setupNeeded)
    }

    func test_castable_tab_puts_panel_in_idle_castable() {
        let state = makeState(FakeRunner())
        state.apply(tab: TabRef(url: "https://youtu.be/a", title: "A", browser: .chrome),
                    status: .empty)
        XCTAssertEqual(state.panel, .idleCastable)
    }

    func test_plain_page_puts_panel_in_idle_not_castable_with_reason() {
        let state = makeState(FakeRunner())
        state.apply(tab: TabRef(url: "https://news.ycombinator.com", title: "HN", browser: .chrome),
                    status: .empty)
        XCTAssertEqual(state.panel, .idleNotCastable(reason: "Not a video page"))
    }

    func test_playing_status_puts_panel_in_casting_regardless_of_tab() {
        let state = makeState(FakeRunner())
        let playing = CastStatus(title: "X", elapsed: 10, duration: 60, volume: 50, muted: false)
        state.apply(tab: TabRef(url: "https://news.ycombinator.com", title: "HN", browser: .chrome),
                    status: playing)
        XCTAssertEqual(state.panel, .casting)
    }

    func test_volume_is_taken_from_device_status() {
        let state = makeState(FakeRunner())
        state.apply(tab: nil, status: CastStatus(title: nil, elapsed: nil, duration: nil,
                                                 volume: 42, muted: false))
        XCTAssertEqual(state.volume, 42)
    }

    func test_setVolume_sends_command_and_updates_optimistically() throws {
        let r = FakeRunner()
        let state = makeState(r)
        state.selectedDevice = DeviceInfo(ip: "1.2.3.4", name: "TV", model: "TCL")
        state.setVolume(70)
        XCTAssertEqual(state.volume, 70)
        XCTAssertEqual(r.calls.last?.args, ["-d", "TV", "volume", "70"])
    }

    func test_cast_failure_surfaces_message_and_does_not_crash() {
        let r = FakeRunner()
        r.stubbedOutput = "Error: Nothing is currently playing."
        let state = makeState(r)
        state.selectedDevice = DeviceInfo(ip: "1.2.3.4", name: "TV", model: "TCL")
        state.tab = TabRef(url: "https://youtu.be/a", title: "A", browser: .chrome)
        state.castCurrentTab()
        XCTAssertEqual(state.lastError, "Nothing is currently playing.")
    }

    func test_casting_without_a_device_reports_no_device() {
        let state = makeState(FakeRunner())
        state.selectedDevice = nil
        state.tab = TabRef(url: "https://youtu.be/a", title: "A", browser: .chrome)
        state.castCurrentTab()
        XCTAssertEqual(state.lastError, "No device selected")
    }

    func test_elapsed_label_formats_as_mmss() {
        let state = makeState(FakeRunner())
        state.apply(tab: nil, status: CastStatus(title: "X", elapsed: 72, duration: 188,
                                                 volume: 50, muted: false))
        XCTAssertEqual(state.elapsedLabel, "1:12")
        XCTAssertEqual(state.remainingLabel, "−1:56")
    }
}
