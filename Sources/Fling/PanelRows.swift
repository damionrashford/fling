import SwiftUI
import FlingKit

// MARK: - primitives

/// `Divider()` renders almost invisibly on the popover's material, so this
/// draws an explicit hairline instead.
struct Separator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.13))
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }
}

/// 3pt track, 11pt knob — the stock `Slider` is too heavy for a menu panel.
struct SlimSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100

    private let knob: CGFloat = 11

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18)).frame(height: 3)
                Capsule().fill(Color.primary.opacity(0.85))
                    .frame(width: max(0, w * frac), height: 3)
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
                    .offset(x: min(max(0, w * frac - knob / 2), w - knob))
            }
            .frame(height: knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let f = min(1, max(0, g.location.x / max(w, 1)))
                    value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                }
            )
        }
        .frame(height: knob)
    }
}

/// Matching 3pt bar for playback position, tinted rather than system-grey.
struct SlimProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.18)).frame(height: 3)
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * min(max(value, 0), 1), height: 3)
            }
        }
        .frame(height: 3)
    }
}

/// Real preview image when the URL yields one, gradient placeholder otherwise.
struct Artwork: View {
    let url: URL?
    var height: CGFloat = 84

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.18, green: 0.23, blue: 0.32),
                                    Color(red: 0.29, green: 0.20, blue: 0.32)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        placeholderGlyph
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                placeholderGlyph
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var placeholderGlyph: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 22))
            .foregroundStyle(.white.opacity(0.35))
    }
}

// MARK: - rows

/// A menu-flavoured row: tight, with an optional right-aligned shortcut.
struct MenuRow: View {
    let title: String
    var icon: String? = nil
    var shortcut: String? = nil
    var accented = false
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(accented ? Color.accentColor : Color.secondary)
                        .frame(width: 15)
                }
                Text(title)
                    .foregroundStyle(accented ? Color.accentColor : Color.primary)
                    .fontWeight(accented ? .semibold : .regular)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && enabled ? Color.accentColor.opacity(0.2) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.32)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
    }
}

/// Occupies the same slot in every panel state.
struct VolumeRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 13)

            SlimSlider(value: Binding(
                get: { Double(state.volume) },
                set: { state.setVolume(Int($0.rounded())) }
            ))

            Text("\(state.volume)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

/// Tiny uppercase section heading.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// PIN entry for Android TV Remote pairing, shown while the TV displays its
/// 6-character code.
struct TVPinEntry: View {
    @ObservedObject var state: AppState
    @State private var pin = ""

    private var verifying: Bool { state.tvPairing == .verifying }
    private var code: String { pin.trimmingCharacters(in: .whitespaces).uppercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter the code on the TV screen")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("A1B2C3", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(verifying)
                    .onSubmit { submit() }
                if verifying {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Pair") { submit() }
                        .font(.system(size: 11.5))
                        .disabled(code.count != 6)
                    Button("Cancel") { Task { await state.cancelTVPairing() } }
                        .font(.system(size: 11.5))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func submit() {
        guard code.count == 6 else { return }
        Task { await state.submitTVPIN(code) }
    }
}

/// Always the last row of the panel, in every state.
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
        .padding(.top, 5)
        .padding(.bottom, 9)
    }
}

/// Shown whenever more than one supported browser is installed, running or
/// not, so a browser with no windows open stays reachable.
struct SourcePicker: View {
    @ObservedObject var state: AppState
    let options: [Browser]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options) { browser in
                let selected = state.activeBrowser == browser
                Button(browser.displayName) { Task { await state.select(browser: browser) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3.5)
                    .background(selected ? Color.accentColor.opacity(0.18)
                                         : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 2)
    }
}
