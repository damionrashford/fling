import AppKit

/// macOS grants Automation consent per target app, so Chrome, Safari, and
/// System Events are three independent prompts. Probing during onboarding
/// raises all of them up front rather than at the first cast.
public struct PermissionProbe: @unchecked Sendable {
    private let reader: BrowserReader
    private let installed: [Browser]
    private let cache: GrantCache

    /// Grants are effectively never revoked mid-session, so a browser that
    /// once probed as granted skips the `osascript` spawn for the process
    /// lifetime; a denial always re-probes so a fresh grant is noticed.
    static let sharedCache = GrantCache()

    final class GrantCache: @unchecked Sendable {
        private let lock = NSLock()
        private var granted: Set<Browser> = []
        func contains(_ browser: Browser) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return granted.contains(browser)
        }
        func insert(_ browser: Browser) {
            lock.lock(); defer { lock.unlock() }
            granted.insert(browser)
        }
    }

    public init(runner: ProcessRunning = SystemProcessRunner(),
                installed: [Browser] = Browser.allCases) {
        self.init(runner: runner, installed: installed, cache: Self.sharedCache)
    }

    /// Tests inject a fresh cache so runs stay independent.
    init(runner: ProcessRunning, installed: [Browser], cache: GrantCache) {
        self.reader = BrowserReader(runner: runner)
        self.installed = installed
        self.cache = cache
    }

    /// Attempting the read is the only reliable probe: macOS exposes no API to
    /// query Automation consent without triggering it. Blocking — each probe
    /// spawns `osascript`, so call this off the main actor.
    public func missingGrants() -> [Browser] {
        installed.filter { browser in
            if cache.contains(browser) { return false }
            do { _ = try reader.readTab(browser) }
            catch BrowserError.permissionDenied { return true }
            catch {}   // no windows, unreadable — consent was given
            cache.insert(browser)
            return false
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
