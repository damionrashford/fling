import Foundation

public struct JXARunner: @unchecked Sendable {
    private let runner: ProcessRunning
    public init(runner: ProcessRunning = SystemProcessRunner()) { self.runner = runner }

    /// Not JavaScript's `eval` — this hands a script to `/usr/bin/osascript` as an
    /// argv entry, never through a shell. Every caller passes a compile-time
    /// constant built from the `Browser` enum, so no user input reaches the script
    /// and there is no injection surface.
    public func eval(_ script: String) throws -> String {
        try runner.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
