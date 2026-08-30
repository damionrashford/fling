import AppKit
import SwiftUI
import FlingKit

/// Development-only. `Fling --preview-panel` renders the panel's states in a
/// normal window; the menu bar popover cannot be opened programmatically, so
/// this is the only way to screenshot the design. `FLING_PREVIEW=hero` renders
/// the single panel used for the README screenshot.
enum PreviewHarness {

    /// Returns "" for everything: no subprocess runs and no device is contacted.
    private struct StubRunner: ProcessRunning {
        func run(_ executable: String, _ args: [String]) throws -> String { "" }
    }

    @MainActor
    static func makeState(_ configure: (AppState) -> Void) -> AppState {
        let state = AppState(catt: CattClient(executable: "/nonexistent", runner: StubRunner()),
                             browsers: BrowserReader(runner: StubRunner()))
        state.devices = [DeviceInfo(ip: "192.168.1.42", name: "Living room TV", model: "TCL Smart TV")]
        state.selectedDevice = state.devices.first
        state.activeBrowser = .chrome
        configure(state)
        return state
    }

    @MainActor
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let idleUnpaired = makeState {
            $0.apply(tab: TabRef(url: "https://www.youtube.com/watch?v=gCcx85zbxz4",
                                 title: "Big Buck Bunny — Official Trailer",
                                 browser: .chrome),
                     status: CastStatus(title: nil, elapsed: nil, duration: nil,
                                        volume: 64, muted: false))
        }
        let idlePaired = makeState {
            $0.apply(tab: TabRef(url: "https://news.ycombinator.com",
                                 title: "Hacker News", browser: .chrome),
                     status: CastStatus(title: nil, elapsed: nil, duration: nil,
                                        volume: 64, muted: false))
            $0.applyTVRemote(paired: true, isOn: true, currentApp: nil)
        }
        let ambiguous = makeState {
            $0.apply(tab: TabRef(url: "https://www.youtube.com/watch?v=gCcx85zbxz4",
                                 title: "Blade Runner 2049 — Official Trailer",
                                 browser: .chrome),
                     status: CastStatus(title: nil, elapsed: nil, duration: nil,
                                        volume: 64, muted: false))
        }
        let castingPaired = makeState {
            $0.apply(tab: TabRef(url: "https://www.youtube.com/watch?v=gCcx85zbxz4",
                                 title: "Blade Runner 2049 — Official Trailer",
                                 browser: .chrome),
                     status: CastStatus(title: "Blade Runner 2049 — Official Trailer",
                                        elapsed: 72, duration: 188, volume: 64, muted: false))
            $0.applyTVRemote(paired: true, isOn: true, currentApp: "com.netflix.ninja")
        }

        if ProcessInfo.processInfo.environment["FLING_PREVIEW"] == "hero" {
            show(labelled("", castingPaired).padding(30),
                 size: NSSize(width: 404, height: 1040), app: app)
            return
        }

        show(HStack(alignment: .top, spacing: 22) {
                labelled("idle · unpaired", idleUnpaired)
                labelled("idle · paired", idlePaired)
                labelled("two browsers", ambiguous)
                labelled("casting · paired", castingPaired)
             }
             .padding(26),
             size: NSSize(width: 1500, height: 1100), app: app)
    }

    @MainActor
    private static func show(_ root: some View, size: NSSize, app: NSApplication) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Fling"
        window.contentView = NSHostingView(
            rootView: root.background(Color(nsColor: .windowBackgroundColor)))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    @MainActor
    private static func labelled(_ title: String, _ state: AppState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            PanelView(state: state, probesPermissions: false)
                .fixedSize()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}
