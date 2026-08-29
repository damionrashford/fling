import Foundation
import Combine

/// Android TV pairing progress, driven by AppState and rendered by the panel.
public enum TVPairing: Equatable {
    case idle
    /// `startPairing` in flight — the TV shows its PIN when this completes.
    case starting
    case waitingForPIN
    case verifying
    case failed(String)
}

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
    /// True when the selected device has completed Android TV Remote pairing.
    @Published public private(set) var tvPaired = false
    @Published public private(set) var tvPairing: TVPairing = .idle
    /// nil until a remote session has reported power state.
    @Published public private(set) var tvIsOn: Bool?
    /// Foreground app package the TV last reported, nil when unknown.
    @Published public private(set) var tvCurrentApp: String?
    /// True while the Mac microphone is streaming to the TV's voice search.
    @Published public private(set) var tvVoiceActive = false

    private let catt: CattClient?
    private let browsers: BrowserReader
    private let atv: AndroidTVRemote?
    private var atvEvents: Task<Void, Never>?
    private var voiceCapture: VoiceCapture?
    private var voiceFeed: AsyncStream<Data>.Continuation?
    private var voiceSendTask: Task<Void, Never>?
    private var lastUsedBrowser: Browser?
    private var refreshing = false
    private var volumeTask: Task<Void, Never>?

    /// How long the volume slider settles before a command is sent. Dragging
    /// emits an event per pixel, and each one would spawn a `catt` subprocess.
    public static let volumeDebounce = Duration.milliseconds(180)

    public init(catt: CattClient?, browsers: BrowserReader, atv: AndroidTVRemote? = nil) {
        self.catt = catt
        self.browsers = browsers
        self.atv = atv
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

    /// Setter for previews and tests. In production these values arrive only
    /// from pairing and the remote session's event stream.
    public func applyTVRemote(paired: Bool, isOn: Bool?, currentApp: String?) {
        tvPaired = paired
        tvIsOn = isOn
        tvCurrentApp = currentApp
    }

    /// Pure transition, separated from I/O so it can be tested directly.
    public func apply(tab: TabRef?, status: CastStatus) {
        self.tab = tab
        self.status = status
        if let v = status.volume { self.volume = v }

        guard catt != nil else { panel = .setupNeeded; return }

        // hasMedia, not isPlaying — a paused video is still casting.
        if status.hasMedia {
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

    /// Every call here is blocking subprocess I/O — `catt scan` alone takes
    /// about ten seconds — so it must run off the main actor.
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
            refreshTVPaired()
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

        // Read the chosen browser directly: refresh() would let
        // frontmost-resolution override the explicit choice.
        let reader = self.browsers
        let tab = await Task.detached(priority: .userInitiated) {
            try? reader.readTab(browser)
        }.value
        apply(tab: tab, status: status)
    }

    public func select(device: DeviceInfo) async {
        selectedDevice = device
        refreshTVPaired()
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

    public func wakeTV() async {
        await send { catt, device in try catt.wake(device: device) }
    }

    // MARK: - TV power (Android TV Remote)

    public func startTVPairing() async {
        guard let atv else { return }
        guard let host = selectedDevice?.ip else { lastError = "No device selected"; return }
        tvPairing = .starting
        do {
            try await atv.startPairing(host: host)
            tvPairing = .waitingForPIN
        } catch {
            tvPairing = .failed(Self.atvMessage(error))
        }
    }

    public func submitTVPIN(_ pin: String) async {
        guard let atv else { return }
        tvPairing = .verifying
        do {
            try await atv.finishPairing(pin: pin)
            tvPairing = .idle
            refreshTVPaired()
        } catch {
            tvPairing = .failed(Self.atvMessage(error))
        }
    }

    public func cancelTVPairing() async {
        await atv?.cancelPairing()
        tvPairing = .idle
    }

    public func toggleTVPower() async {
        guard let atv else { return }
        guard let host = selectedDevice?.ip else { lastError = "No device selected"; return }
        watchATVEvents()
        do {
            try await atv.togglePower(host: host)
            tvIsOn = await atv.isOn
            lastError = nil
        } catch {
            lastError = Self.atvMessage(error)
        }
    }

    public func launchTVApp(_ app: TVApp) async {
        await sendATV { atv, host in try await atv.launchApp(link: app.link, host: host) }
    }

    public func pressTVKey(_ code: Int32) async {
        await sendATV { atv, host in try await atv.pressKey(code, host: host) }
    }

    public func sendTVText(_ text: String) async {
        guard !text.isEmpty else { return }
        await sendATV { atv, host in try await atv.sendText(text, host: host) }
    }

    /// One press opens voice search on the TV and starts streaming the Mac
    /// microphone; the next press ends the utterance.
    public func toggleVoiceSearch() async {
        if tvVoiceActive { await endVoiceSearch(); return }
        guard let atv else { return }
        guard let host = selectedDevice?.ip else { lastError = "No device selected"; return }
        watchATVEvents()
        do {
            try await atv.beginVoice(host: host)
            let capture = VoiceCapture()
            let (chunks, feed) = AsyncStream<Data>.makeStream()
            try capture.start { feed.yield($0) }
            // A single consumer keeps chunks in utterance order; a Task per
            // chunk would let them interleave.
            voiceSendTask = Task {
                for await chunk in chunks { try? await atv.sendVoice(pcm: chunk) }
            }
            voiceCapture = capture
            voiceFeed = feed
            tvVoiceActive = true
            lastError = nil
        } catch {
            lastError = Self.atvMessage(error)
        }
    }

    public func endVoiceSearch() async {
        guard tvVoiceActive else { return }
        let tail = voiceCapture?.stop() ?? Data()
        if !tail.isEmpty { voiceFeed?.yield(tail) }
        voiceFeed?.finish()
        await voiceSendTask?.value
        voiceCapture = nil
        voiceFeed = nil
        voiceSendTask = nil
        tvVoiceActive = false
        if let atv { try? await atv.endVoice() }
    }

    private func refreshTVPaired() {
        guard let atv, let host = selectedDevice?.ip else { tvPaired = false; return }
        tvPaired = atv.hasPairing(host: host)
    }

    /// Counterpart of `send` for the remote session: resolves the host, starts
    /// consuming the event stream, and routes failures into `lastError`.
    private func sendATV(_ body: (AndroidTVRemote, String) async throws -> Void) async {
        guard let atv else { return }
        guard let host = selectedDevice?.ip else { lastError = "No device selected"; return }
        watchATVEvents()
        do {
            try await body(atv, host)
            lastError = nil
        } catch {
            lastError = Self.atvMessage(error)
        }
    }

    /// The TV pushes power flips over the open session; without this the row
    /// label would update only after a toggle sent from here.
    private func watchATVEvents() {
        guard atvEvents == nil, let atv else { return }
        atvEvents = Task { [weak self] in
            for await event in await atv.events() {
                switch event {
                case .connected: break
                case .powerChanged(let on): self?.tvIsOn = on
                case .appChanged(let package): self?.tvCurrentApp = package
                case .disconnected:
                    self?.tvIsOn = nil
                    self?.tvCurrentApp = nil
                }
            }
        }
    }

    private static func atvMessage(_ error: Error) -> String {
        switch error {
        case ATVError.invalidPIN:
            return "That code doesn't match — read it off the TV again."
        case ATVError.serverStatus:
            return "The TV rejected the pairing code. Start over."
        case ATVError.connectionFailed, ATVError.connectionTimeout, ATVError.connectionClosed:
            return "Couldn't reach the TV. If this keeps happening, re-run TV power setup."
        case ATVError.notPaired, ATVError.pairingNotStarted:
            return "Run TV power setup first."
        default:
            return error.localizedDescription
        }
    }

    /// Updates the slider immediately and sends the command once dragging
    /// settles. Synchronous because the UI binding must not await.
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
