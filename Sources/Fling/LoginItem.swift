import AppKit
import ServiceManagement

/// Shared by the panel and the right-click menu so the two surfaces can never
/// disagree about whether Fling launches at login.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Fling: login item toggle failed — \(error.localizedDescription)")
        }
    }
}
