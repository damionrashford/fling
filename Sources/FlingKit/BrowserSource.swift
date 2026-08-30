import AppKit

/// Seam over NSWorkspace so tests can fake which apps are running and
/// frontmost without touching the real workspace.
public protocol RunningAppsReading: Sendable {
    func isRunning(bundleID: String) -> Bool
    func frontmostBundleID() -> String?
}

public struct WorkspaceAppsReader: RunningAppsReading {
    public init() {}

    public func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    public func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

/// `@unchecked Sendable` for the same reason as `CattClient`: immutable, and
/// used from detached tasks so `osascript` never blocks the main actor.
public struct BrowserReader: @unchecked Sendable {
    private let jxa: JXARunner
    private let apps: RunningAppsReading

    public init(runner: ProcessRunning = SystemProcessRunner(),
                apps: RunningAppsReading = WorkspaceAppsReader()) {
        self.jxa = JXARunner(runner: runner)
        self.apps = apps
    }

    /// NSWorkspace, not System Events: zero subprocess spawns per refresh,
    /// and reading the running list can never launch the browser.
    public func isRunning(_ browser: Browser) -> Bool {
        apps.isRunning(bundleID: browser.bundleIdentifier)
    }

    /// Only a frontmost *browser* is meaningful to the resolver — a
    /// non-browser app in front never matches anything — so this maps the
    /// frontmost bundle id to the browser's process name or nil.
    public func frontmostApp() -> String? {
        guard let front = apps.frontmostBundleID() else { return nil }
        return Browser.allCases.first { $0.bundleIdentifier == front }?.processName
    }

    public func readTab(_ browser: Browser) throws -> TabRef {
        let result = try jxa.run(browser.tabSnippet)

        // Permission denial is classified only from stderr of a failed run:
        // stdout carries the page's own title/URL, which can legitimately
        // mention "-1743" or "not authorized".
        guard result.succeeded else {
            let err = result.stderr.lowercased()
            if err.contains("-1743") || err.contains("not authorized") {
                throw BrowserError.permissionDenied(browser)
            }
            throw BrowserError.unreadable(
                browser, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            throw BrowserError.unreadable(browser, output)
        }
        if json["error"] == "no-windows" { throw BrowserError.noWindows(browser) }
        guard let url = json["url"] else { throw BrowserError.unreadable(browser, output) }

        return TabRef(url: url, title: json["title"] ?? "", browser: browser)
    }
}
