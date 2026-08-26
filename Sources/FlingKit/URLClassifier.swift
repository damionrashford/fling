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

    /// The video id from any YouTube URL shape, or nil. Used to build a real
    /// thumbnail so the idle panel can show what it is about to cast.
    public static func youTubeVideoID(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased(),
              youtubeHosts.contains(host)
        else { return nil }

        // youtu.be/<id>, /embed/<id>, /shorts/<id>
        let segments = components.path.split(separator: "/").map(String.init)
        if host == "youtu.be", let id = segments.first { return id.nilIfEmpty }
        if segments.count >= 2, segments[0] == "embed" || segments[0] == "shorts" {
            return segments[1].nilIfEmpty
        }
        // watch?v=<id>
        return components.queryItems?.first(where: { $0.name == "v" })?.value?.nilIfEmpty
    }
}
