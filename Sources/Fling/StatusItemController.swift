import AppKit
import SwiftUI
import Combine
import FlingKit

@MainActor
final class StatusItemController: NSObject {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let state: AppState
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        // No fixed contentSize — the panel's height varies by state (artwork,
        // transport rows), and pinning it clipped the taller states.
        let host = NSHostingController(rootView: PanelView(state: state))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "Fling")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Redraw the title whenever elapsed time or panel state changes.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)

        updateTitle()
        startPolling()

        // Deliberately NOT awaited here. `refresh()` is subprocess I/O; blocking
        // init on it prevents the run loop from ever drawing the status item.
        Task { await state.refresh() }
    }

    /// Polls only while the popover is open or something is casting — there is
    /// no reason to hit the device once a second while the menu bar is idle.
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.popover.isShown || self.state.panel == .casting else { return }
                await self.state.refresh()
            }
        }
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        button.title = state.panel == .casting ? " \(state.elapsedLabel)" : ""
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        isRightClick ? showMenu(from: sender) : togglePopover(sender)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await state.refresh() }
        }
    }

    /// `popUp` is used rather than assigning `statusItem.menu`, which would
    /// permanently hijack left-click and stop the popover from ever opening.
    private func showMenu(from button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }
        let menu = ContextMenuBuilder(state: state).build()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }
}
