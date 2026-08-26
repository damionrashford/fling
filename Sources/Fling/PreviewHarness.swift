import AppKit
import SwiftUI
import FlingKit

/// Development-only. `Fling --preview-panel` renders every panel state in a
/// normal window so the design can be screenshotted and compared against the
/// mockups. The menu bar popover cannot be opened programmatically — driving an
/// NSStatusItem through the Accessibility API hangs — so without this there is
/// no way to look at the UI except by hand.
enum PreviewHarness {

    /// Returns "" for everything, so no subprocess is ever spawned and no
    /// device on the network is contacted.
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

        let idleCastable = makeState {
            $0.apply(tab: TabRef(url: "https://www.youtube.com/watch?v=gCcx85zbxz4",
                                 title: "Big Buck Bunny — Official Trailer",
                                 browser: .chrome),
                     status: CastStatus(title: nil, elapsed: nil, duration: nil,
                                        volume: 64, muted: false))
        }
        let idleBlocked = makeState {
            $0.apply(tab: TabRef(url: "https://news.ycombinator.com",
                                 title: "Hacker News", browser: .chrome),
                     status: CastStatus(title: nil, elapsed: nil, duration: nil,
                                        volume: 64, muted: false))
        }
        let ambiguous = makeState {
            $0.sourceChoice = .ambiguous([.chrome, .safari])
            $0.apply(tab: TabRef(url: "https://www.youtube.com/watch?v=gCcx85zbxz4",
                                 title: "Blade Runner 2049 — Official Trailer",
                                 browser: .chrome),
                     status: CastStatus(title: nil, elapsed: nil, duration: nil,
                                        volume: 64, muted: false))
        }
        let casting = makeState {
            $0.apply(tab: TabRef(url: "https://www.youtube.com/watch?v=gCcx85zbxz4",
                                 title: "Blade Runner 2049 — Official Trailer",
                                 browser: .chrome),
                     status: CastStatus(title: "Blade Runner 2049 — Official Trailer",
                                        elapsed: 72, duration: 188, volume: 64, muted: false))
        }

        let root = HStack(alignment: .top, spacing: 22) {
            labelled("idle · castable", idleCastable)
            labelled("idle · blocked", idleBlocked)
            labelled("idle · two browsers", ambiguous)
            labelled("casting", casting)
        }
        .padding(26)
        .background(Color(nsColor: .windowBackgroundColor))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1260, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Fling — panel states"
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    @MainActor
    private static func labelled(_ title: String, _ state: AppState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            PanelView(state: state, probesPermissions: false)
                .fixedSize()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}
