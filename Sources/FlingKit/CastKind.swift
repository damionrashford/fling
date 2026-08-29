/// How a given URL must be handed to the Cast device.
public enum CastKind: Equatable, Sendable {
    /// A direct media file or manifest. MUST be cast with `catt cast -f`.
    case directMedia
    /// A YouTube URL. `catt` launches the YouTube receiver app (233637DE).
    case youtube
    /// A site yt-dlp can extract a stream from. Plain `catt cast`.
    case extractableSite
    /// Cannot be cast. `reason` is shown verbatim to the user in the panel.
    case notCastable(reason: String)

    public var isCastable: Bool {
        if case .notCastable = self { return false }
        return true
    }
}
