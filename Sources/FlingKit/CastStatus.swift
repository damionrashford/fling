import Foundation

public struct CastStatus: Equatable, Sendable {
    public let title: String?
    public let elapsed: TimeInterval?
    public let duration: TimeInterval?
    public let volume: Int?
    public let muted: Bool

    public var isPlaying: Bool { title != nil && elapsed != nil }

    public var remaining: TimeInterval? {
        guard let elapsed, let duration, duration > elapsed else { return nil }
        return duration - elapsed
    }

    public static let empty = CastStatus(title: nil, elapsed: nil, duration: nil,
                                         volume: nil, muted: false)

    public init(title: String?, elapsed: TimeInterval?, duration: TimeInterval?,
                volume: Int?, muted: Bool) {
        self.title = title; self.elapsed = elapsed; self.duration = duration
        self.volume = volume; self.muted = muted
    }
}
