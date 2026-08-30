import Foundation

/// Turns continuous trackpad/wheel deltas into discrete d-pad steps.
/// Pure state machine so the gesture feel is unit-testable; the UI layer
/// feeds it NSEvent deltas and sends the returned keycodes.
public struct ScrollNav {

    /// Points of accumulated scroll per d-pad step.
    public static let step: CGFloat = 55
    /// Minimum spacing between emitted steps; a fast flick should move a few
    /// rows, not teleport across the whole grid.
    public static let minInterval: TimeInterval = 0.09
    /// Line-based wheels report ~1pt "lines" where trackpads report real
    /// points, so wheels need a boost to feel equivalent.
    public static let wheelScale: CGFloat = 10

    private var accX: CGFloat = 0
    private var accY: CGFloat = 0
    private var lastEmit: TimeInterval = -.infinity

    public init() {}

    /// Feed one scroll event; returns the keycodes to send, oldest first.
    /// `precise` is NSEvent.hasPreciseScrollingDeltas; `momentum` events
    /// (inertial tail) are ignored so a flick can't run away.
    public mutating func consume(dx: CGFloat, dy: CGFloat, precise: Bool,
                                 momentum: Bool, at now: TimeInterval) -> [Int32] {
        guard !momentum else { return [] }
        let scale: CGFloat = precise ? 1 : Self.wheelScale
        accX += dx * scale
        accY += dy * scale

        // Dominant axis only: diagonal intent is rare on a d-pad and firing
        // both axes makes navigation feel drunk.
        if abs(accX) > abs(accY) { accY = 0 } else { accX = 0 }

        var keys: [Int32] = []
        while max(abs(accX), abs(accY)) >= Self.step, keys.count < 2 {
            guard now - lastEmit >= Self.minInterval else { break }
            if abs(accX) > abs(accY) {
                keys.append(accX > 0 ? ATVKeyCode.dpadLeft : ATVKeyCode.dpadRight)
                accX -= Self.step * (accX > 0 ? 1 : -1)
            } else {
                keys.append(accY > 0 ? ATVKeyCode.dpadUp : ATVKeyCode.dpadDown)
                accY -= Self.step * (accY > 0 ? 1 : -1)
            }
            lastEmit = now
        }
        return keys
    }

    /// Drops any partial accumulation, e.g. when the panel closes.
    public mutating func reset() {
        accX = 0; accY = 0
    }
}
