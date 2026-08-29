import AppKit
import FlingKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var shortcuts: GlobalShortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let catt = CattClient.resolveExecutable().map {
            CattClient(executable: $0, runner: SystemProcessRunner())
        }
        // Voice on: KEYCODE_SEARCH becomes mic-listening on the TV, and the
        // panel's mic button feeds it. Typed search still works via IME text.
        let state = AppState(catt: catt, browsers: BrowserReader(),
                             atv: AndroidTVRemote(enableVoice: true))
        controller = StatusItemController(state: state)
        shortcuts = GlobalShortcuts(state: state)
    }
}
