import XCTest
@testable import FlingKit

final class BrowserResolverTests: XCTestCase {

    func test_no_browser_running_returns_none() {
        XCTAssertEqual(
            BrowserResolver.resolve(running: [], frontmostApp: "Finder", lastUsed: nil),
            .none)
    }

    func test_rule1_frontmost_browser_wins_over_lastUsed() {
        XCTAssertEqual(
            BrowserResolver.resolve(running: [.chrome, .safari],
                                    frontmostApp: "Safari", lastUsed: .chrome),
            .single(.safari))
    }

    func test_rule2_lastUsed_wins_when_neither_is_frontmost() {
        XCTAssertEqual(
            BrowserResolver.resolve(running: [.chrome, .safari],
                                    frontmostApp: "Finder", lastUsed: .chrome),
            .single(.chrome))
    }

    func test_rule3_only_running_browser_wins() {
        XCTAssertEqual(
            BrowserResolver.resolve(running: [.safari], frontmostApp: "Finder", lastUsed: nil),
            .single(.safari))
    }

    func test_rule3_lastUsed_is_ignored_when_not_running() {
        XCTAssertEqual(
            BrowserResolver.resolve(running: [.safari], frontmostApp: "Finder", lastUsed: .chrome),
            .single(.safari))
    }

    func test_rule4_ambiguous_when_both_run_neither_frontmost_and_no_history() {
        XCTAssertEqual(
            BrowserResolver.resolve(running: [.chrome, .safari],
                                    frontmostApp: "Finder", lastUsed: nil),
            .ambiguous([.chrome, .safari]))
    }

    func test_frontmost_app_that_is_not_a_browser_is_ignored() {
        XCTAssertEqual(
            BrowserResolver.resolve(running: [.chrome], frontmostApp: "Xcode", lastUsed: nil),
            .single(.chrome))
    }

    func test_ambiguous_list_is_stable_in_declaration_order() {
        guard case .ambiguous(let list) = BrowserResolver.resolve(
            running: [.safari, .chrome], frontmostApp: nil, lastUsed: nil)
        else { return XCTFail("expected ambiguous") }
        XCTAssertEqual(list, [.chrome, .safari])
    }
}
