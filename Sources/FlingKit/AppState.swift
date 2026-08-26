import Foundation
import Combine

@MainActor
public final class AppState: ObservableObject {

    @Published public private(set) var panel: PanelState
    @Published public private(set) var status: CastStatus = .empty
    @Published public var tab: TabRef?
    @Published public var devices: [DeviceInfo] = []
    @Published public var selectedDevice: DeviceInfo?
    @Published public var sourceChoice: SourceChoice = .none
    @Published public var volume: Int = 50
    @Published public var lastError: String?
    /// Browsers present on this Mac, running or not. Drives picker visibility.
    @Published public var installedBrowsers: [Browser] = Browser.installed
    /// Which browser the panel is currently reading from.
    @Published public var activeBrowser: Browser?

    private let catt: CattClient?
    private let browsers: BrowserReader
    private var lastUsedBrowser: Browser?
    private var refreshing = false
    private var volumeTask: Task<Void, Never>?

    /// How long the volume slider settles before a command is sent. Dragging a
    /// slider emits an event per pixel; without this, each one would spawn a
    /// `catt` subprocess and hammer the TV.
    public static let volumeDebounce = Duration.milliseconds(180)

    public init(catt: CattClient?, browsers: BrowserReader) {
        self.catt = catt
        self.browsers = browsers
        self.panel = catt == nil ? .setupNeeded : .idleNotCastable(reason: "No page open")
    }

    // MARK: - derived labels

    public var elapsedLabel: String { Self.clock(status.elapsed) }
    public var remainingLabel: String {
        guard let r = status.remaining else { return "" }
        return "−" + Self.clock(r)
    }
    public var progress: Double {
        guard let e = status.elapsed, let d = status.duration, d > 0 else { return 0 }
        return min(1, e / d)
    }

    private static func clock(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    // MARK: - state transitions

    /// Pure transition, separated from I/O so it can be tested directly.
    public func apply(tab: TabRef?, status: CastStatus) {
        self.tab = tab
        self.status = status
        if let v = status.volume { self.volume = v }

        guard catt != nil else { panel = .setupNeeded; return }

        if status.isPlaying {
            panel = .casting
        } else if let tab, tab.kind.isCastable {
            panel = .idleCastable
        } else if case .notCastable(let reason)? = tab?.kind {
            panel = .idleNotCastable(reason: reason)
        } else {
            panel = .idleNotCastable(reason: "No page open")
        }
    }

    // MARK: - refresh

    /// Every call here is blocking subprocess I/O — `catt scan` alone takes about
    /// ten seconds. It MUST run off the main actor, or the menu bar never draws.
    public func refresh() async {
        guard let catt, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let browsers = self.browsers
        let lastUsed = self.lastUsedBrowser
        let knownDevice = self.selectedDevice?.name
        let needsScan = self.devices.isEmpty

        let result = await Task.detached(priority: .userInitiated) { () -> RefreshResult in
            let found = needsScan ? (try? catt.scan()) : nil

            let running = Browser.allCases.filter { browsers.isRunning($0) }
            let choice = BrowserResolver.resolve(running: running,
                                                 frontmostApp: browsers.frontmostApp(),
                                                 lastUsed: lastUsed)
            var newTab: TabRef?
            if case .single(let browser) = choice { newTab = try? browsers.readTab(browser) }

            let deviceName = knownDevice ?? found?.first?.name
            let status = deviceName.flatMap { try? catt.status(device: $0) } ?? .empty

            return RefreshResult(devices: found, choice: choice, tab: newTab, status: status)
        }.value

        if let found = result.devices {
            devices = found
            if selectedDevice == nil { selectedDevice = found.first }
        }
        sourceChoice = result.choice
        if case .single(let browser) = result.choice { activeBrowser = browser }
        apply(tab: result.tab, status: result.status)
    }

    private struct RefreshResult: Sendable {
        let devices: [DeviceInfo]?
        let choice: SourceChoice
        let tab: TabRef?
        let status: CastStatus
    }

    // MARK: - actions

    public func select(browser: Browser) async {
        lastUsedBrowser = browser
        activeBrowser = browser
        sourceChoice = .single(browser)

        // Read the chosen browser directly. Going through refresh() would let
        // frontmost-resolution override the explicit choice the user just made.
        let reader = self.browsers
        let tab = await Task.detached(priority: .userInitiated) {
            try? reader.readTab(browser)
        }.value
        apply(tab: tab, status: status)
    }

    public func select(device: DeviceInfo) async {
        selectedDevice = device
        await refresh()
    }

    public func castCurrentTab() async {
        guard let tab else { lastError = "No page open"; return }
        lastUsedBrowser = tab.browser
        await cast(tab.url, kind: tab.kind)
    }

    public func castClipboard() async {
        guard let raw = ClipboardReader.read() else { lastError = "Clipboard is empty"; return }
        await cast(raw, kind: URLClassifier.classify(raw))
    }

    public func togglePlayPause() async {
        let playing = status.isPlaying
        await send { catt, device in
            playing ? try catt.pause(device: device) : try catt.play(device: device)
        }
    }

    public func seek(by seconds: Int) async {
        await send { catt, device in try catt.seek(by: seconds, device: device) }
    }

    public func stopCasting() async {
        await send { catt, device in try catt.stop(device: device) }
    }

    /// Updates the slider immediately and sends the command once dragging settles.
    /// Sync on purpose — the UI binding must not await.
    public func setVolume(_ level: Int) {
        volume = min(100, max(0, level))
        let target = volume
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.volumeDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.send { catt, device in try catt.setVolume(target, device: device) }
        }
    }

    /// Awaits any in-flight debounced volume command. For tests and for shutdown.
    public func flushVolume() async {
        await volumeTask?.value
    }

    // MARK: - plumbing

    private func cast(_ url: String, kind: CastKind) async {
        if case .notCastable(let reason) = kind { lastError = reason; return }
        await send { catt, device in try catt.cast(url, kind: kind, device: device) }
    }

    /// Runs a blocking `catt` command off the main actor, then reports the
    /// outcome back on it.
    private func send(_ body: @escaping @Sendable (CattClient, String) throws -> Void) async {
        guard let catt else { lastError = "catt is not installed"; return }
        guard let device = selectedDevice?.name else { lastError = "No device selected"; return }

        let failure = await Task.detached(priority: .userInitiated) { () -> String? in
            do { try body(catt, device); return nil }
            catch let error as CattError { return error.message }
            catch { return error.localizedDescription }
        }.value

        lastError = failure
    }
}
