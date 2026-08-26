import Foundation

/// `@unchecked Sendable` for the same reason as `CattClient` — immutable, and
/// used from detached tasks so `osascript` never blocks the main actor.
public struct BrowserReader: @unchecked Sendable {
    private let jxa: JXARunner

    public init(runner: ProcessRunning = SystemProcessRunner()) {
        self.jxa = JXARunner(runner: runner)
    }

    /// Asked via System Events so the browser is never launched as a side effect
    /// of the check — addressing the app directly would start it.
    public func isRunning(_ browser: Browser) -> Bool {
        let script = """
        Application("System Events").processes.whose({name: "\(browser.processName)"}).length > 0
        """
        return (try? jxa.eval(script))?.lowercased() == "true"
    }

    public func frontmostApp() -> String? {
        let script = #"Application("System Events").applicationProcesses.whose({frontmost: true})[0].name()"#
        guard let name = try? jxa.eval(script), !name.isEmpty else { return nil }
        return name
    }

    public func readTab(_ browser: Browser) throws -> TabRef {
        let output = try jxa.eval(browser.tabSnippet)

        if output.contains("-1743") || output.lowercased().contains("not authorized") {
            throw BrowserError.permissionDenied(browser)
        }
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
