import SwiftUI
import FlingKit

/// A menu-flavoured row: tight, with an optional right-aligned shortcut.
struct MenuRow: View {
    let title: String
    var shortcut: String? = nil
    var accented = false
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(accented ? Color.accentColor : Color.primary)
                    .fontWeight(accented ? .semibold : .regular)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && enabled ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .padding(.horizontal, 4)
    }
}

/// Rule 2: this row occupies the same slot in every state.
struct VolumeRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Slider(value: Binding(
                get: { Double(state.volume) },
                set: { state.setVolume(Int($0.rounded())) }
            ), in: 0...100)
            .controlSize(.mini)

            Text("\(state.volume)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

/// Rule 3: always the footer, never moves.
struct DeviceFooter: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state.selectedDevice == nil ? Color.secondary : Color.green)
                .frame(width: 6, height: 6)
            Text(state.selectedDevice?.name ?? "No device found")
                .font(.system(size: 11.5))
                .lineLimit(1)
            Spacer()
            if state.devices.count > 1 {
                Menu("Switch") {
                    ForEach(state.devices) { device in
                        Button(device.name) { Task { await state.select(device: device) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// Rule 1: only rendered when both browsers are actually running.
struct SourcePicker: View {
    @ObservedObject var state: AppState
    let options: [Browser]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { browser in
                let selected = state.tab?.browser == browser
                Button(browser.displayName) { Task { await state.select(browser: browser) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(selected ? Color.accentColor.opacity(0.22)
                                         : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
    }
}
