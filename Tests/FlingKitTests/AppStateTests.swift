import XCTest
@testable import FlingKit

@MainActor
final class AppStateTests: XCTestCase {

    private func makeState(_ runner: FakeRunner) -> AppState {
        AppState(catt: CattClient(executable: "/usr/bin/catt", runner: runner),
                 browsers: BrowserReader(runner: runner))
    }

    // MARK: - state transitions

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

    func test_elapsed_label_formats_as_mmss() {
        let state = makeState(FakeRunner())
        state.apply(tab: nil, status: CastStatus(title: "X", elapsed: 72, duration: 188,
                                                 volume: 50, muted: false))
        XCTAssertEqual(state.elapsedLabel, "1:12")
        XCTAssertEqual(state.remainingLabel, "−1:56")
    }

    // MARK: - volume

    func test_setVolume_updates_the_slider_immediately() {
        let state = makeState(FakeRunner())
        state.selectedDevice = DeviceInfo(ip: "1.2.3.4", name: "TV", model: "TCL")
        state.setVolume(70)
        // Optimistic — the UI must not wait on a subprocess.
        XCTAssertEqual(state.volume, 70)
    }

    func test_setVolume_sends_the_command_after_the_debounce() async {
        let r = FakeRunner()
        let state = makeState(r)
        state.selectedDevice = DeviceInfo(ip: "1.2.3.4", name: "TV", model: "TCL")
        state.setVolume(70)
        await state.flushVolume()
        XCTAssertEqual(r.calls.last?.args, ["-d", "1.2.3.4", "volume", "70"])
    }

    /// Dragging the slider emits an event per pixel; without debouncing each
    /// one spawns a `catt` subprocess.
    func test_rapid_volume_changes_collapse_to_a_single_command() async {
        let r = FakeRunner()
        let state = makeState(r)
        state.selectedDevice = DeviceInfo(ip: "1.2.3.4", name: "TV", model: "TCL")

        for level in stride(from: 30, through: 70, by: 5) { state.setVolume(level) }
        await state.flushVolume()

        let volumeCalls = r.calls.filter { $0.args.contains("volume") }
        XCTAssertEqual(volumeCalls.count, 1, "expected one command, got \(volumeCalls.count)")
        XCTAssertEqual(volumeCalls.last?.args, ["-d", "1.2.3.4", "volume", "70"])
    }

    // MARK: - actions

    func test_cast_failure_surfaces_message_and_does_not_crash() async {
        let r = FakeRunner()
        r.stubbedOutput = "Error: Nothing is currently playing."
        let state = makeState(r)
        state.selectedDevice = DeviceInfo(ip: "1.2.3.4", name: "TV", model: "TCL")
        state.tab = TabRef(url: "https://youtu.be/a", title: "A", browser: .chrome)
        await state.castCurrentTab()
        XCTAssertEqual(state.lastError, "Nothing is currently playing.")
    }

    func test_casting_without_a_device_reports_no_device() async {
        let state = makeState(FakeRunner())
        state.selectedDevice = nil
        state.tab = TabRef(url: "https://youtu.be/a", title: "A", browser: .chrome)
        await state.castCurrentTab()
        XCTAssertEqual(state.lastError, "No device selected")
    }

    func test_casting_a_plain_page_reports_the_reason_without_invoking_catt() async {
        let r = FakeRunner()
        let state = makeState(r)
        state.selectedDevice = DeviceInfo(ip: "1.2.3.4", name: "TV", model: "TCL")
        state.tab = TabRef(url: "https://news.ycombinator.com", title: "HN", browser: .chrome)
        await state.castCurrentTab()
        XCTAssertEqual(state.lastError, "Not a video page")
        XCTAssertTrue(r.calls.isEmpty)
    }

    /// `refresh()` must run its blocking subprocess I/O off the main actor, or
    /// the run loop never draws the status item.
    func test_refresh_completes_without_blocking_the_main_actor() async {
        let r = FakeRunner()
        r.stubbedOutput = "Volume: 50\nVolume muted: False"
        let state = makeState(r)
        await state.refresh()
        XCTAssertFalse(r.calls.isEmpty, "refresh should have performed its I/O")
    }
}
