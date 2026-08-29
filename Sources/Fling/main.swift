import AppKit

if CommandLine.arguments.contains("--preview-panel") {
    // Top-level code always runs on the main thread; the compiler cannot
    // prove it, so state it rather than hopping actors.
    MainActor.assumeIsolated { PreviewHarness.run() }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
