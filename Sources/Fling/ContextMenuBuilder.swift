import AppKit
import ServiceManagement
import FlingKit

@MainActor
struct ContextMenuBuilder {
    let state: AppState

    func build() -> NSMenu {
        let menu = NSMenu()
        // Without this, AppKit ignores `isEnabled` and auto-enables everything.
        menu.autoenablesItems = false

        let casting = state.panel == .casting
        let castable = state.panel == .idleCastable || casting

        menu.addItem(action(casting ? "Cast this tab instead" : "Cast this tab",
                            key: "C", modifiers: [.command, .shift],
                            enabled: castable) { Task { await state.castCurrentTab() } })
        menu.addItem(action("Cast clipboard URL") { Task { await state.castClipboard() } })
        menu.addItem(.separator())

        if case .ambiguous(let options) = state.sourceChoice {
            menu.addItem(submenu("Source", items: options.map { browser in
                action(browser.displayName) { Task { await state.select(browser: browser) } }
            }))
        }
        if !state.devices.isEmpty {
            menu.addItem(submenu("Device", items: state.devices.map { device in
                let item = action(device.name) { Task { await state.select(device: device) } }
                item.state = device == state.selectedDevice ? .on : .off
                return item
            }))
        }
        menu.addItem(.separator())

        menu.addItem(action(state.status.isPlaying ? "Pause" : "Play",
                            enabled: casting) { Task { await state.togglePlayPause() } })
        menu.addItem(action("Back 30s", enabled: casting) { Task { await state.seek(by: -30) } })
        menu.addItem(action("Forward 30s", enabled: casting) { Task { await state.seek(by: 30) } })

        // A native menu genuinely cannot hold a slider — presets instead.
        menu.addItem(submenu("Volume — \(state.volume)%",
                             items: stride(from: 0, through: 100, by: 10).map { level in
            let item = action("\(level)%") { state.setVolume(level) }
            item.state = abs(state.volume - level) < 5 ? .on : .off
            return item
        }))

        menu.addItem(.separator())
        menu.addItem(action("Stop casting", key: ".", modifiers: [.command],
                            enabled: casting) { Task { await state.stopCasting() } })
        menu.addItem(.separator())

        let login = action("Open at Login") { toggleLoginItem() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(action("Quit Fling", key: "q", modifiers: [.command]) {
            NSApp.terminate(nil)
        })
        return menu
    }

    // MARK: - helpers

    private func action(_ title: String,
                        key: String = "",
                        modifiers: NSEvent.ModifierFlags = [],
                        enabled: Bool = true,
                        handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Trampoline.fire), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = enabled
        let trampoline = Trampoline(handler)
        item.target = trampoline
        item.representedObject = trampoline   // keeps the trampoline alive
        return item
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        items.forEach { sub.addItem($0) }
        parent.submenu = sub
        return parent
    }

    private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Fling: login item toggle failed — \(error.localizedDescription)")
        }
    }
}

/// `NSMenuItem` needs an ObjC target; this carries a Swift closure to one.
final class Trampoline: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
