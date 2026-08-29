/// An app on the TV the panel can launch. `link` is the Android app-link the
/// remote protocol opens; `package` is the Android package name the TV reports
/// as the foreground app, used to label "Now: …".
public struct TVApp: Identifiable, Equatable, Sendable {
    public let name: String
    public let link: String
    public let package: String

    public var id: String { package }

    public init(name: String, link: String, package: String) {
        self.name = name; self.link = link; self.package = package
    }
}

public extension TVApp {
    /// The remote protocol has no "list installed apps" call, so the launcher
    /// is a curated catalog. Links follow the Home Assistant androidtv_remote
    /// community lists and are not verified per TV model.
    /// Custom schemes route uniquely to the app; https links make Android TV
    /// offer a browser/chooser instead. Apps without a scheme use the bare
    /// package name, which the transport turns into a market:// launch — that
    /// opens the installed app directly.
    static let catalog: [TVApp] = [
        TVApp(name: "YouTube", link: "vnd.youtube.launch://",
              package: "com.google.android.youtube.tv"),
        TVApp(name: "Netflix", link: "netflix://",
              package: "com.netflix.ninja"),
        TVApp(name: "Prime Video", link: "com.amazon.amazonvideo.livingroom",
              package: "com.amazon.amazonvideo.livingroom"),
        TVApp(name: "Disney+", link: "com.disney.disneyplus",
              package: "com.disney.disneyplus"),
        TVApp(name: "Spotify", link: "spotify://",
              package: "com.spotify.tv.android"),
        TVApp(name: "Plex", link: "plex://",
              package: "com.plexapp.android"),
        TVApp(name: "Tubi", link: "com.tubitv",
              package: "com.tubitv"),
    ]

    /// Panel label for a foreground package: catalog name, else the last
    /// package component capitalized ("com.tcl.browser" → "Browser").
    static func displayName(forPackage package: String) -> String {
        if let known = catalog.first(where: { $0.package == package }) { return known.name }
        let tail = package.split(separator: ".").last.map(String.init) ?? package
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }
}
