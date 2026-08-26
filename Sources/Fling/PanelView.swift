import SwiftUI
import AppKit
import FlingKit

struct PanelView: View {
    @ObservedObject var state: AppState
    /// Off in the preview harness — probing spawns osascript and would trigger
    /// real consent dialogs just to look at the design.
    var probesPermissions = true
    @State private var missingGrants: [Browser] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if missingGrants.isEmpty {
                switch state.panel {
                case .setupNeeded:                 setup
                case .casting:                     casting
                case .idleCastable:                idle(reason: nil)
                case .idleNotCastable(let reason): idle(reason: reason)
                }
            } else {
                OnboardingView(missing: missingGrants) { await recheckPermissions() }
            }
        }
        .frame(width: 260)
        // Probing spawns osascript per browser — never on the main actor.
        .task { await recheckPermissions() }
    }

    private func recheckPermissions() async {
        guard probesPermissions else { return }
        missingGrants = await PermissionProbe().missingGrantsAsync()
        if missingGrants.isEmpty { await state.refresh() }
    }

    // MARK: - setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fling needs catt").font(.system(size: 13, weight: .semibold))
            Text("The Cast engine isn't installed. Install it once and Fling will find it.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy install command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("uv tool install catt", forType: .string)
            }
            .font(.system(size: 11.5))
        }
        .padding(14)
    }

    // MARK: - idle

    private func idle(reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Shown whenever both browsers are installed, so a closed browser is
            // still reachable.
            if state.installedBrowsers.count > 1 {
                SourcePicker(state: state, options: state.installedBrowsers)
            }

            // Only when the URL actually yields a preview image.
            if let thumb = state.tab?.thumbnailURL {
                Artwork(url: thumb).padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.tab?.title.nilIfEmpty ?? "No page open")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineSpacing(1)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(host).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.secondary)
                    if let reason {
                        Text(reason).foregroundStyle(.orange)
                    } else {
                        Text("castable").foregroundStyle(.green)
                    }
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

            Separator()

            // Rule 4 — the only accented row. Rule 5 — stays visible when disabled.
            MenuRow(title: "Cast this tab", shortcut: "⌘⇧C",
                    accented: reason == nil, enabled: reason == nil) {
                Task { await state.castCurrentTab() }
            }
            if let reason { inlineWhy(reason) }

            MenuRow(title: "Cast clipboard URL") { Task { await state.castClipboard() } }

            Separator()
            VolumeRow(state: state)          // Rule 2
            Separator()
            housekeeping
            DeviceFooter(state: state)       // Rule 3
        }
    }

    /// Above the device footer, so rule 3 still holds — the device never moves.
    private var housekeeping: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: LoginItem.isEnabled ? "✓ Open at Login" : "Open at Login") {
                LoginItem.toggle()
            }
            MenuRow(title: "Quit Fling", shortcut: "⌘Q") { NSApp.terminate(nil) }
            Separator()
        }
    }

    // MARK: - casting

    private var casting: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Present here too, so "Cast this tab instead" can target either browser.
            if state.installedBrowsers.count > 1 {
                SourcePicker(state: state, options: state.installedBrowsers)
                    .padding(.bottom, 8)
            }
            artwork

            VStack(alignment: .leading, spacing: 3) {
                Text(state.status.title ?? "Playing")
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(host).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 10)

            VStack(spacing: 5) {
                SlimProgress(value: state.progress)
                HStack {
                    Text(state.elapsedLabel)
                    Spacer()
                    Text(state.remainingLabel)
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 5)

            MenuRow(title: state.status.isPlaying ? "Pause" : "Play", shortcut: "Space") {
                Task { await state.togglePlayPause() }
            }
            MenuRow(title: "Back 30s", shortcut: "←") { Task { await state.seek(by: -30) } }
            MenuRow(title: "Forward 30s", shortcut: "→") { Task { await state.seek(by: 30) } }

            VolumeRow(state: state)          // Rule 2 — same slot as idle

            Separator()
            MenuRow(title: "Cast this tab instead", shortcut: "⌘⇧C") {
                Task { await state.castCurrentTab() }
            }
            MenuRow(title: "Stop casting", shortcut: "⌘.") { Task { await state.stopCasting() } }

            Separator()
            housekeeping
            DeviceFooter(state: state)       // Rule 3
        }
    }

    private var artwork: some View { Artwork(url: state.tab?.thumbnailURL) }

    // Rule 5 — the failure explains itself where it happened.
    private func inlineWhy(_ reason: String) -> some View {
        Text(explanation(for: reason))
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.bottom, 7)
    }

    private func explanation(for reason: String) -> String {
        switch reason {
        case "Not a video page":
            return "Chromecast plays media streams, not web pages. Try a video page."
        case "No page open":
            return "Open a tab in Chrome or Safari, then try again."
        default:
            return reason
        }
    }

    private var host: String {
        guard let raw = state.tab?.url, let h = URL(string: raw)?.host else { return "—" }
        return h.replacingOccurrences(of: "www.", with: "")
    }
}
