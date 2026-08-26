import Foundation

public struct URLClassifier {

    /// Containers and manifests the Cast Default Media Receiver plays directly.
    /// Source: https://developers.google.com/cast/docs/media
    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "webm", "ts", "mp3", "m4a", "aac", "ogg", "oga", "wav", "flac",
        "m3u8",  // HLS
        "mpd",   // DASH
    ]

    static let youtubeHosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com",
        "music.youtube.com", "youtu.be",
    ]

    /// Sites yt-dlp reliably extracts a single stream from.
    static let extractableHosts: Set<String> = [
        "vimeo.com", "player.vimeo.com",
        "twitch.tv", "www.twitch.tv",
        "dailymotion.com", "www.dailymotion.com",
        "twitter.com", "x.com",
        "reddit.com", "www.reddit.com",
        "soundcloud.com",
    ]

    public static func classify(_ raw: String?) -> CastKind {
        guard let raw, !raw.isEmpty, raw != "missing value" else {
            return .notCastable(reason: "No page open")
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else {
            return .notCastable(reason: "Not a web page")
        }

        if youtubeHosts.contains(host) { return .youtube }

        // pathExtension already excludes the query string.
        if mediaExtensions.contains(url.pathExtension.lowercased()) { return .directMedia }

        if extractableHosts.contains(host) { return .extractableSite }

        return .notCastable(reason: "Not a video page")
    }
}
