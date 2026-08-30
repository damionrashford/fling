import Foundation

/// What a finished (or killed) subprocess produced, with stdout and stderr
/// kept apart so callers can classify errors without sniffing page content
/// or media titles for error-looking strings.
public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// True when the child outlived the timeout and was killed; `exitCode`
    /// then reflects the signal, not a real status.
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// A clean run: exited 0 within the deadline.
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum ProcessTimeout {
    /// Generous on purpose: the point is that a wedged child gets killed at
    /// all, not that it gets killed fast.
    public static let `default`: TimeInterval = 30
}

public protocol ProcessRunning {
    /// Runs `executable` with `args`, capturing stdout and stderr separately
    /// and killing the child if it outlives `timeout`.
    func run(_ executable: String, _ args: [String], timeout: TimeInterval) throws -> ProcessResult

    /// Legacy convenience: merged stdout+stderr, no exit status.
    func run(_ executable: String, _ args: [String]) throws -> String
}

/// Mutual defaults so a conformer implements either method alone: production
/// runners provide the structured one, older fakes/stubs only the string one.
public extension ProcessRunning {
    func run(_ executable: String, _ args: [String]) throws -> String {
        let result = try run(executable, args, timeout: ProcessTimeout.default)
        return result.stdout + result.stderr
    }

    func run(_ executable: String, _ args: [String], timeout: TimeInterval) throws -> ProcessResult {
        // A merged-only conformer has no status to report; a clean exit is assumed.
        ProcessResult(exitCode: 0, stdout: try run(executable, args), stderr: "")
    }
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, _ args: [String],
                    timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Armed before launch so a fast exit cannot beat the handler.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        // Both pipes drain off-thread: a child filling the un-read pipe would
        // deadlock against the exit wait.
        let stdoutBuf = Buffer(), stderrBuf = Buffer()
        let drained = DispatchGroup()
        for (pipe, buffer) in [(out, stdoutBuf), (err, stderrBuf)] {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                // Chunked, not readDataToEndOfFile: output produced before a
                // kill must survive even if something still holds the pipe.
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                drained.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // SIGTERM first so catt/osascript can clean up; SIGKILL only if
            // the child ignores it.
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        // Reaps the child even after a kill, so no zombie is left behind.
        process.waitUntilExit()
        // Bounded: a grandchild inheriting the pipes could hold them open
        // forever, and partial output beats hanging the caller again.
        _ = drained.wait(timeout: .now() + 5)

        return ProcessResult(exitCode: process.terminationStatus,
                             stdout: stdoutBuf.text(),
                             stderr: stderrBuf.text(),
                             timedOut: timedOut)
    }

    /// Lock-guarded because the drain may still be writing when the bounded
    /// wait above gives up.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
