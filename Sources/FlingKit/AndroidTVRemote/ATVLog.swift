import Foundation

/// Append-only diagnostic log at ~/Library/Logs/Fling.log for the Android TV
/// protocol, whose live failures are otherwise invisible: the TV closes
/// without explanation and the interesting part is which handshake step it
/// closed after. Synchronous by design — lines are rare (lifecycle +
/// handshake) and must land before the failure that follows them.
public final class ATVLog: @unchecked Sendable {

    public static let shared = ATVLog(
        fileURL: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Fling.log"))

    private let fileURL: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var openFailed = false

    private let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `2026-08-29T12:34:56.789Z [tag] message` — one line per call. Logging
    /// must never break the feature it observes, so every failure here is
    /// swallowed and turns the logger into a no-op.
    public func log(_ tag: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            guard !openFailed else { return }
            handle = openHandle()
            if handle == nil { openFailed = true; return }
        }
        let line = "\(timestamp.string(from: Date())) [\(tag)] \(message)\n"
        // Seek every line: other processes (or a second client) may have
        // appended since ours.
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    private func openHandle() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: fileURL)
    }
}
