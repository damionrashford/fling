import XCTest
@testable import FlingKit

final class ScrollNavTests: XCTestCase {

    func test_small_deltas_accumulate_before_emitting() {
        var nav = ScrollNav()
        XCTAssertEqual(nav.consume(dx: 0, dy: -20, precise: true, momentum: false, at: 0), [])
        XCTAssertEqual(nav.consume(dx: 0, dy: -20, precise: true, momentum: false, at: 0.05), [])
        XCTAssertEqual(nav.consume(dx: 0, dy: -20, precise: true, momentum: false, at: 0.1),
                       [ATVKeyCode.dpadDown])
    }

    func test_scroll_up_emits_dpad_up() {
        var nav = ScrollNav()
        XCTAssertEqual(nav.consume(dx: 0, dy: 60, precise: true, momentum: false, at: 0),
                       [ATVKeyCode.dpadUp])
    }

    func test_horizontal_dominant_axis_wins() {
        var nav = ScrollNav()
        XCTAssertEqual(nav.consume(dx: -80, dy: 10, precise: true, momentum: false, at: 0),
                       [ATVKeyCode.dpadRight])
    }

    func test_momentum_events_are_ignored() {
        var nav = ScrollNav()
        XCTAssertEqual(nav.consume(dx: 0, dy: -300, precise: true, momentum: true, at: 0), [])
    }

    func test_wheel_lines_are_scaled_up() {
        var nav = ScrollNav()
        // A single wheel notch (~6 line-units) should be one step, not noise.
        XCTAssertEqual(nav.consume(dx: 0, dy: -6, precise: false, momentum: false, at: 0),
                       [ATVKeyCode.dpadDown])
    }

    func test_giant_flick_is_capped_per_event() {
        var nav = ScrollNav()
        let keys = nav.consume(dx: 0, dy: -1000, precise: true, momentum: false, at: 0)
        XCTAssertLessThanOrEqual(keys.count, 2)
    }

    func test_rapid_steps_are_rate_limited() {
        var nav = ScrollNav()
        _ = nav.consume(dx: 0, dy: -60, precise: true, momentum: false, at: 0)
        XCTAssertEqual(nav.consume(dx: 0, dy: -60, precise: true, momentum: false, at: 0.01), [])
        XCTAssertEqual(nav.consume(dx: 0, dy: -1, precise: true, momentum: false, at: 0.2),
                       [ATVKeyCode.dpadDown])
    }

    func test_reset_drops_partial_accumulation() {
        var nav = ScrollNav()
        _ = nav.consume(dx: 0, dy: -40, precise: true, momentum: false, at: 0)
        nav.reset()
        XCTAssertEqual(nav.consume(dx: 0, dy: -20, precise: true, momentum: false, at: 1), [])
    }
}
