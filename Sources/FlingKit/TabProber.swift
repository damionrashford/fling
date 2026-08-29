import Foundation

public enum TabProbeError: Error, Equatable {
    /// The browser's "Allow JavaScript from Apple Events" toggle is off.
    /// Chrome: View → Developer; Safari: the Develop menu.
    case jsFromAppleEventsDisabled(Browser)
    case probeFailed(String)
}

/// What the injected detector found in the active tab.
public struct TabMedia: Equatable, Sendable {
    /// Best directly castable stream, nil if none found. blob: URLs are not
    /// castable, so an MSE player yields its sniffed manifest here instead.
    public let streamURL: String?
    /// Position worth resuming; nil when < 5s in or unknown.
    public let resumeAt: TimeInterval?
    public let duration: TimeInterval?
    public let isPlaying: Bool

    public init(streamURL: String?, resumeAt: TimeInterval?, duration: TimeInterval?, isPlaying: Bool) {
        self.streamURL = streamURL
        self.resumeAt = resumeAt
        self.duration = duration
        self.isPlaying = isPlaying
    }
}

/// `@unchecked Sendable` for the same reason as `BrowserReader`: immutable,
/// and run from detached tasks so `osascript` never blocks the main actor.
public struct TabProber: @unchecked Sendable {
    private let jxa: JXARunner

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.jxa = JXARunner(runner: runner)
    }

    /// nil = page probed fine but has no media element.
    public func probe(_ browser: Browser) throws -> TabMedia? {
        let output: String
        do { output = try jxa.eval(browser.probeSnippet) }
        catch { throw TabProbeError.probeFailed("\(error)") }
        return try TabProber.parse(output, browser: browser)
    }

    /// Read-only page-side collector: never mutates the page. One IIFE
    /// expression because Safari's `do JavaScript` returns the last
    /// statement's value and forbids top-level `return`. `duration` is null
    /// for live streams (Infinity) so it survives JSON. Manifests are
    /// reversed because `performance` entries are chronological and the
    /// latest one is what an MSE player is actually playing.
    static let detectorScript = #"""
    (() => {
      try {
        var els = Array.prototype.slice.call(document.querySelectorAll("video,audio")).map(function (e) {
          return {
            src: e.currentSrc || e.src || "",
            time: Number.isFinite(e.currentTime) ? e.currentTime : null,
            duration: Number.isFinite(e.duration) ? e.duration : null,
            paused: !!e.paused
          };
        });
        var manifests = performance.getEntriesByType("resource")
          .map(function (r) { return String(r.name); })
          .filter(function (n) { return /\.(m3u8|mpd)(\?|#|$)/i.test(n); })
          .reverse()
          .slice(0, 8);
        return JSON.stringify({ elements: els, manifests: manifests });
      } catch (e) {
        return JSON.stringify({ error: String(e) });
      }
    })()
    """#

    /// JSON escaping yields a valid JS string literal without hand-managed
    /// backslashes; wrapped in an array because top-level string fragments
    /// aren't encodable on every Foundation this package targets.
    static var detectorLiteral: String {
        let wrapped = try! JSONEncoder().encode([detectorScript])
        return String(String(decoding: wrapped, as: UTF8.self).dropFirst().dropLast())
    }

    /// Both refusal messages name the toggle verbatim. Chrome's own phrasing
    /// is kept as a second marker in case Google reworks the remediation
    /// text. Chrome captured live (error 12); Safari per Apple's documented
    /// `do JavaScript` refusal (error 8).
    private static let disabledMarkers = [
        "allow javascript from apple events",
        "executing javascript through applescript is turned off",
    ]

    static func isHTTP(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private struct Payload: Decodable {
        struct Element: Decodable {
            let src: String
            let time: Double?
            let duration: Double?
            let paused: Bool
        }
        let error: String?
        let elements: [Element]?
        let manifests: [String]?
    }

    static func parse(_ output: String, browser: Browser) throws -> TabMedia? {
        guard let data = output.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            let lower = output.lowercased()
            if disabledMarkers.contains(where: lower.contains) {
                throw TabProbeError.jsFromAppleEventsDisabled(browser)
            }
            throw TabProbeError.probeFailed(output)
        }
        if let error = payload.error { throw TabProbeError.probeFailed(error) }

        // A sourceless <video> with no metadata is a player shell, not media.
        let candidates = (payload.elements ?? []).filter { !($0.src.isEmpty && $0.duration == nil) }
        guard !candidates.isEmpty else { return nil }

        // The playing element is the one the user cares about; among several,
        // the longest is the main feature rather than an ad or a preview.
        let playing = candidates.filter { !$0.paused }
        let pool = playing.isEmpty ? candidates : playing
        let main = pool.max { ($0.duration ?? 0) < ($1.duration ?? 0) }!

        let streamURL = isHTTP(main.src)
            ? main.src
            : (payload.manifests ?? []).first(where: isHTTP)
        let resumeAt = (main.time ?? 0) >= 5 ? main.time : nil

        return TabMedia(streamURL: streamURL,
                        resumeAt: resumeAt,
                        duration: main.duration,
                        isPlaying: !main.paused)
    }
}

extension Browser {
    /// Verbs per the on-disk sdefs: Chrome's Chromium-suite `execute` takes
    /// the tab as direct parameter with a `javascript` argument; Safari's
    /// `do JavaScript` takes the code with an `in` target. Both are
    /// element-targeted Apple Events, so the browser can stay in the
    /// background.
    var probeSnippet: String {
        let js = TabProber.detectorLiteral
        switch self {
        case .chrome:
            return """
            (() => {
              const app = Application("Google Chrome");
              if (app.windows.length === 0) return JSON.stringify({error: "no-windows"});
              return app.execute(app.windows[0].activeTab, {javascript: \(js)});
            })()
            """
        case .safari:
            return """
            (() => {
              const app = Application("Safari");
              if (app.windows.length === 0) return JSON.stringify({error: "no-windows"});
              return app.doJavaScript(\(js), {in: app.windows[0].currentTab()});
            })()
            """
        }
    }
}
