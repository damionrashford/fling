import AppKit
import FlingKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var shortcuts: GlobalShortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let catt = CattClient.resolveExecutable().map {
            CattClient(executable: $0, runner: SystemProcessRunner())
        }
        let state = AppState(catt: catt, browsers: BrowserReader())
        controller = StatusItemController(state: state)
        shortcuts = GlobalShortcuts(state: state)
    }
}
