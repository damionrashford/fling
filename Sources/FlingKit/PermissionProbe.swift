import AppKit

/// macOS grants Automation consent per target app, so Chrome, Safari, and
/// System Events are three independent prompts. This asks for them deliberately
/// during onboarding instead of ambushing the user at their first cast.
public struct PermissionProbe: @unchecked Sendable {
    private let reader: BrowserReader
    private let installed: [Browser]

    public init(runner: ProcessRunning = SystemProcessRunner(),
                installed: [Browser] = Browser.allCases) {
        self.reader = BrowserReader(runner: runner)
        self.installed = installed
    }

    /// Attempting the read is the only reliable probe — macOS exposes no API to
    /// query Automation consent without triggering it.
    ///
    /// Blocking: each probe spawns `osascript`. Call it off the main actor.
    public func missingGrants() -> [Browser] {
        installed.filter { browser in
            do { _ = try reader.readTab(browser); return false }
            catch BrowserError.permissionDenied { return true }
            catch { return false }   // no windows, unreadable — consent was given
        }
    }

    /// Same probe, run off the main actor so callers never block the UI.
    public func missingGrantsAsync() async -> [Browser] {
        let probe = self
        return await Task.detached(priority: .userInitiated) { probe.missingGrants() }.value
    }

    @MainActor
    public static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
