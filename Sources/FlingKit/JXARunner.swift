import Foundation

public struct JXARunner: @unchecked Sendable {
    private let runner: ProcessRunning
    public init(runner: ProcessRunning = SystemProcessRunner()) { self.runner = runner }

    /// Hands the script to `/usr/bin/osascript` as an argv entry, never through
    /// a shell. Every caller passes a compile-time constant built from the
    /// `Browser` enum, so no user input reaches the script.
    ///
    /// Structured on purpose: osascript reports failures on stderr with a
    /// non-zero exit, which is what permission/toggle classification keys off
    /// — stdout is page-controlled and must never be sniffed for error text.
    public func run(_ script: String,
                    timeout: TimeInterval = ProcessTimeout.default) throws -> ProcessResult {
        try runner.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script],
                       timeout: timeout)
    }

    /// Legacy merged-and-trimmed convenience.
    public func eval(_ script: String) throws -> String {
        let result = try run(script)
        return (result.stdout + result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
