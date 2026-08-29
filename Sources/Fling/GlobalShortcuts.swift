import AppKit
import FlingKit

/// ⌘⇧C is the only system-wide shortcut; the others shown in the UI are menu
/// equivalents, live only while a surface is open.
@MainActor
final class GlobalShortcuts {
    private var monitor: Any?

    init(state: AppState) {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let wanted: NSEvent.ModifierFlags = [.command, .shift]
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == wanted,
                  event.charactersIgnoringModifiers?.lowercased() == "c"
            else { return }
            Task { @MainActor in
                await state.refresh()
                await state.castCurrentTab()
            }
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
