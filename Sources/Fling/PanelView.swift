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
            // Rule 1 — only when both browsers run.
            if case .ambiguous(let options) = state.sourceChoice {
                SourcePicker(state: state, options: options)
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
            DeviceFooter(state: state)       // Rule 3
        }
    }

    // MARK: - casting

    private var casting: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            DeviceFooter(state: state)       // Rule 3
        }
    }

    // Rule 1 — artwork exists only while casting; idle reserves no space for it.
    private var artwork: some View {
        LinearGradient(colors: [Color(red: 0.18, green: 0.23, blue: 0.32),
                                Color(red: 0.29, green: 0.20, blue: 0.32)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(height: 84)
            .overlay(Image(systemName: "play.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.35)))
    }

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
