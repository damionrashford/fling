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
    private var scrollRemote: ScrollRemote?

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        // No fixed contentSize: panel height varies by state, and pinning it
        // clips the taller states.
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

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)

        updateTitle()
        startPolling()
        scrollRemote = ScrollRemote(state: state) { [weak popover] event in
            guard let popover, popover.isShown else { return false }
            return event.window === popover.contentViewController?.view.window
        }

        // Not awaited: `refresh()` is subprocess I/O, and blocking init on it
        // stops the run loop from ever drawing the status item.
        Task { await state.refresh() }
    }

    /// Polls only while the popover is open or something is casting; an idle
    /// menu bar must not hit the device every two seconds.
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.popover.isShown || self.state.panel == .casting else { return }
                // Closed-popover ticks only feed the menu-bar clock; a full
                // refresh would spawn browser reads nothing displays.
                if self.popover.isShown {
                    await self.state.refresh()
                } else {
                    await self.state.refreshStatus()
                }
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
            scrollRemote?.resetGesture()
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await state.refresh() }
        }
    }

    /// Uses `popUp` rather than `statusItem.menu`, which would permanently
    /// hijack left-click and stop the popover from ever opening.
    private func showMenu(from button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }
        let menu = ContextMenuBuilder(state: state).build()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }
}
