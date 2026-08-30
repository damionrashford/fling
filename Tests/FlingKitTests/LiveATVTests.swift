import XCTest
@testable import FlingKit

/// Hardware-in-the-loop driver, disabled unless FLING_LIVE_ATV_HOST is set.
/// FLING_LIVE_ATV_ACTION picks one step: "read" (connect + state, invisible),
/// "key:<code>", "app:<link>", "text:<string>", "power". Results go to stdout
/// and ~/Library/Logs/Fling.log.
final class LiveATVTests: XCTestCase {

    func test_live_action() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["FLING_LIVE_ATV_HOST"] else {
            throw XCTSkip("live ATV driver disabled")
        }
        let action = env["FLING_LIVE_ATV_ACTION"] ?? "read"
        let atv = AndroidTVRemote(enableVoice: true)

        try await atv.connect(host: host)
        let isOn = await atv.isOn
        print("LIVE: connected isOn=\(isOn) action=\(action)")

        switch action.split(separator: ":", maxSplits: 1).map(String.init).first ?? "read" {
        case "read":
            break
        case "key":
            let code = Int32(action.dropFirst(4)) ?? ATVKeyCode.dpadUp
            try await atv.pressKey(code, host: host)
        case "app":
            try await atv.launchApp(link: String(action.dropFirst(4)), host: host)
        case "text":
            try await atv.sendText(String(action.dropFirst(5)), host: host)
        case "power":
            try await atv.togglePower(host: host)
        default:
            XCTFail("unknown action \(action)")
        }

        // Give the TV a beat to push state changes back.
        try await Task.sleep(for: .seconds(3))
        let isOnAfter = await atv.isOn
        print("LIVE: after isOn=\(isOnAfter)")
    }
}
