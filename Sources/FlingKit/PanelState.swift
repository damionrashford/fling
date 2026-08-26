import Foundation

public enum PanelState: Equatable, Sendable {
    /// `catt` could not be found. The panel collapses to a one-click setup row.
    case setupNeeded
    case idleCastable
    case idleNotCastable(reason: String)
    case casting
}
