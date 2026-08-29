import Foundation

/// What to hand `catt`, resolved from the tab plus an optional probe.
public struct CastPlan: Equatable, Sendable {
    public let url: String
    public let kind: CastKind
    public let seekTo: TimeInterval?

    public init(url: String, kind: CastKind, seekTo: TimeInterval?) {
        self.url = url
        self.kind = kind
        self.seekTo = seekTo
    }
}

public enum CastPlanner {
    /// Decides what to actually cast for a tab, given an optional probe result.
    public static func plan(tab: TabRef, media: TabMedia?) -> CastPlan {
        // The prober already gates at 5s; re-gated so the rule holds for any
        // hand-built TabMedia too.
        let resume: TimeInterval?
        if let t = media?.resumeAt, t >= 5 { resume = t } else { resume = nil }

        // The YouTube receiver owns playback and wants the page URL, not the
        // stream the page happens to be feeding its <video>.
        if case .youtube = tab.kind {
            return CastPlan(url: tab.url, kind: .youtube, seekTo: resume)
        }
        if let stream = media?.streamURL, TabProber.isHTTP(stream) {
            return CastPlan(url: stream, kind: .directMedia, seekTo: resume)
        }
        if media != nil {
            // blob-only with no manifest: yt-dlp may still crack the page, so
            // keep the tab's own classification; seek only where the kind can
            // honor it.
            return CastPlan(url: tab.url, kind: tab.kind, seekTo: tab.kind.isCastable ? resume : nil)
        }
        return CastPlan(url: tab.url, kind: tab.kind, seekTo: nil)
    }
}
