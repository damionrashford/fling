import Foundation

/// Reported by `catt status` as a `State:` line. Absent from some outputs, in
/// which case `.unknown` falls back to a title+time heuristic.
public enum PlaybackState: String, Sendable, Equatable {
    case playing, paused, buffering, idle, unknown

    init(catt raw: String) {
        switch raw.uppercased() {
        case "PLAYING":   self = .playing
        case "PAUSED":    self = .paused
        case "BUFFERING": self = .buffering
        case "IDLE":      self = .idle
        default:          self = .unknown
        }
    }
}

public struct CastStatus: Equatable, Sendable {
    public let title: String?
    public let elapsed: TimeInterval?
    public let duration: TimeInterval?
    public let volume: Int?
    public let muted: Bool
    public let state: PlaybackState

    /// Something is loaded on the device — playing OR paused. This is what
    /// decides the casting panel; pausing must not drop back to idle.
    ///
    /// `catt` sometimes omits the `Time:` line mid-playback (observed live), so
    /// an explicit state is trusted over the presence of timing data.
    public var hasMedia: Bool {
        switch state {
        case .playing, .paused, .buffering: return true
        case .idle:                         return false
        case .unknown:                      return title != nil && elapsed != nil
        }
    }

    /// Actively advancing. Drives the Pause/Play label only.
    public var isPlaying: Bool {
        switch state {
        case .playing, .buffering: return true
        case .paused, .idle:       return false
        case .unknown:             return hasMedia
        }
    }

    public var remaining: TimeInterval? {
        guard let elapsed, let duration, duration > elapsed else { return nil }
        return duration - elapsed
    }

    public static let empty = CastStatus(title: nil, elapsed: nil, duration: nil,
                                         volume: nil, muted: false, state: .unknown)

    public init(title: String?, elapsed: TimeInterval?, duration: TimeInterval?,
                volume: Int?, muted: Bool, state: PlaybackState = .unknown) {
        self.title = title; self.elapsed = elapsed; self.duration = duration
        self.volume = volume; self.muted = muted; self.state = state
    }
}
