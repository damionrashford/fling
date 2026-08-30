import AppKit
import FlingKit

/// While the panel is open and the TV is paired, scroll gestures anywhere over
/// the panel drive the TV's d-pad — the panel itself never scrolls, so the
/// whole surface is free to act as a touchpad. Clicks are untouched.
@MainActor
final class ScrollRemote {
    private let state: AppState
    private let isTarget: (NSEvent) -> Bool
    private var monitor: Any?
    private var nav = ScrollNav()

    init(state: AppState, isTarget: @escaping (NSEvent) -> Bool) {
        self.state = state
        self.isTarget = isTarget
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isTarget(event), self.state.tvPaired else { return event }
            let keys = self.nav.consume(dx: event.scrollingDeltaX,
                                        dy: event.scrollingDeltaY,
                                        precise: event.hasPreciseScrollingDeltas,
                                        momentum: event.momentumPhase != [],
                                        at: ProcessInfo.processInfo.systemUptime)
            for key in keys {
                Task { await self.state.pressTVKey(key) }
            }
            return nil   // consumed: nothing in the panel scrolls
        }
    }

    func resetGesture() { nav.reset() }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
