import Foundation
import AppKit

public enum Browser: String, CaseIterable, Sendable, Identifiable {
    case chrome, safari

    public var id: String { rawValue }

    /// Present on this Mac at all — independent of whether it is running or has
    /// windows. The source picker keys off this so it never becomes a dead end
    /// you cannot use to reach a closed browser.
    public static var installed: [Browser] {
        allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
        }
    }

    public var processName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        }
    }

    public var displayName: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        }
    }

    /// Verified against the on-disk scripting dictionaries.
    /// Chrome: window has `active tab`; tab has `URL` and `title`.
    /// Safari: window has `current tab`; tab has `URL` and `name`.
    var tabSnippet: String {
        switch self {
        case .chrome:
            return """
            (() => {
              const app = Application("Google Chrome");
              if (app.windows.length === 0) return JSON.stringify({error: "no-windows"});
              const t = app.windows[0].activeTab;
              return JSON.stringify({url: t.url(), title: t.title()});
            })()
            """
        case .safari:
            return """
            (() => {
              const app = Application("Safari");
              if (app.windows.length === 0) return JSON.stringify({error: "no-windows"});
              const t = app.windows[0].currentTab;
              return JSON.stringify({url: t.url(), title: t.name()});
            })()
            """
        }
    }
}

public struct TabRef: Equatable, Sendable {
    public let url: String
    public let title: String
    public let browser: Browser
    public let kind: CastKind

    /// A real preview image when one can be derived from the URL alone. Nil for
    /// everything else, so the panel reserves no space it cannot fill.
    public var thumbnailURL: URL? {
        guard let id = URLClassifier.youTubeVideoID(url) else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
    }

    public init(url: String, title: String, browser: Browser) {
        self.url = url
        self.title = title
        self.browser = browser
        self.kind = URLClassifier.classify(url)
    }
}

public enum BrowserError: Error, Equatable {
    case noWindows(Browser)
    case notRunning(Browser)
    case permissionDenied(Browser)
    case unreadable(Browser, String)
}
