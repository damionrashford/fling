import AppKit
import FlingKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?
    private var shortcuts: GlobalShortcuts?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let catt = CattClient.resolveExecutable().map {
            CattClient(executable: $0, runner: SystemProcessRunner())
        }
        // With voice negotiated, KEYCODE_SEARCH puts the TV into mic-listening
        // mode; typed search still works through IME text.
        let state = AppState(catt: catt, browsers: BrowserReader(),
                             atv: AndroidTVRemote(enableVoice: true),
                             prober: TabProber())
        controller = StatusItemController(state: state)
        shortcuts = GlobalShortcuts(state: state)
    }
}
