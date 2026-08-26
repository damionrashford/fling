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

    private let catt: CattClient?
    private let browsers: BrowserReader
    private var lastUsedBrowser: Browser?

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

    // MARK: - actions

    public func refresh() {
        guard let catt else { return }
        lastError = nil

        if devices.isEmpty, let found = try? catt.scan() {
            devices = found
            if selectedDevice == nil { selectedDevice = found.first }
        }

        let running = Browser.allCases.filter { browsers.isRunning($0) }
        sourceChoice = BrowserResolver.resolve(running: running,
                                               frontmostApp: browsers.frontmostApp(),
                                               lastUsed: lastUsedBrowser)

        var newTab: TabRef?
        if case .single(let browser) = sourceChoice {
            newTab = try? browsers.readTab(browser)
        }

        let newStatus = selectedDevice.flatMap { try? catt.status(device: $0.name) } ?? .empty
        apply(tab: newTab, status: newStatus)
    }

    public func select(browser: Browser) {
        lastUsedBrowser = browser
        sourceChoice = .single(browser)
        refresh()
    }

    public func select(device: DeviceInfo) {
        selectedDevice = device
        refresh()
    }

    public func castCurrentTab() {
        guard let tab else { lastError = "No page open"; return }
        cast(tab.url, kind: tab.kind)
        lastUsedBrowser = tab.browser
    }

    public func castClipboard() {
        guard let raw = ClipboardReader.read() else { lastError = "Clipboard is empty"; return }
        cast(raw, kind: URLClassifier.classify(raw))
    }

    public func togglePlayPause() {
        perform { catt, device in
            self.status.isPlaying ? try catt.pause(device: device) : try catt.play(device: device)
        }
    }

    public func seek(by seconds: Int) {
        perform { catt, device in try catt.seek(by: seconds, device: device) }
    }

    public func stopCasting() {
        perform { catt, device in try catt.stop(device: device) }
    }

    public func setVolume(_ level: Int) {
        volume = min(100, max(0, level))   // optimistic; the slider must not lag
        perform { catt, device in try catt.setVolume(level, device: device) }
    }

    // MARK: - plumbing

    private func cast(_ url: String, kind: CastKind) {
        if case .notCastable(let reason) = kind { lastError = reason; return }
        perform { catt, device in try catt.cast(url, kind: kind, device: device) }
    }

    private func perform(_ body: (CattClient, String) throws -> Void) {
        guard let catt else { lastError = "catt is not installed"; return }
        guard let device = selectedDevice?.name else { lastError = "No device selected"; return }
        do {
            try body(catt, device)
            lastError = nil
        } catch let error as CattError {
            lastError = error.message
        } catch {
            lastError = error.localizedDescription
        }
    }
}
