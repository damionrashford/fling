public enum PanelState: Equatable, Sendable {
    /// `catt` could not be found; the panel collapses to a setup row.
    case setupNeeded
    case idleCastable
    case idleNotCastable(reason: String)
    case casting
}
