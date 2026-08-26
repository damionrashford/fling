import AppKit

if CommandLine.arguments.contains("--preview-panel") {
    // Top-level code always runs on the main thread; the compiler just can't
    // prove it, so state that explicitly rather than hopping actors.
    MainActor.assumeIsolated { PreviewHarness.run() }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
