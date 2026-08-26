import Foundation

public enum Browser: String, CaseIterable, Sendable, Identifiable {
    case chrome, safari

    public var id: String { rawValue }

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
