import Foundation

public struct CattError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// `@unchecked Sendable`: both stored properties are `let`, and the production
/// runner (`SystemProcessRunner`) is a stateless struct. Instances are handed to
/// detached tasks so blocking subprocess calls stay off the main actor.
public final class CattClient: @unchecked Sendable {
    private let executable: String
    private let runner: ProcessRunning

    public init(executable: String, runner: ProcessRunning = SystemProcessRunner()) {
        self.executable = executable
        self.runner = runner
    }

    /// GUI apps do not inherit the shell's PATH, so the uv tool location is
    /// checked explicitly before falling back to a PATH lookup.
    public static func resolveExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/catt",
            "/opt/homebrew/bin/catt",
            "/usr/local/bin/catt",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - commands

    public func scan() throws -> [DeviceInfo] {
        CattParser.parseScan(try invoke(["scan"]))
    }

    public func status(device: String) throws -> CastStatus {
        CattParser.parseStatus(try invoke(["-d", device, "status"]))
    }

    public func cast(_ url: String, kind: CastKind, device: String) throws {
        let flags: [String]
        switch kind {
        case .directMedia:
            flags = ["cast", "-f", url]
        case .youtube, .extractableSite:
            flags = ["cast", url]
        case .notCastable(let reason):
            throw CattError(reason)
        }
        _ = try invoke(["-d", device] + flags)
    }

    public func setVolume(_ level: Int, device: String) throws {
        let clamped = min(100, max(0, level))
        _ = try invoke(["-d", device, "volume", String(clamped)])
    }

    public func pause(device: String) throws { _ = try invoke(["-d", device, "pause"]) }
    public func play(device: String) throws { _ = try invoke(["-d", device, "play"]) }
    public func stop(device: String) throws { _ = try invoke(["-d", device, "stop"]) }

    public func seek(by seconds: Int, device: String) throws {
        let verb = seconds >= 0 ? "ffwd" : "rewind"
        _ = try invoke(["-d", device, verb, String(abs(seconds))])
    }

    // MARK: - plumbing

    /// `catt` exits 0 while printing errors to stdout, so the output is always
    /// inspected rather than trusting the exit status.
    private func invoke(_ args: [String]) throws -> String {
        let output = try runner.run(executable, args)
        if let message = CattParser.parseError(output) { throw CattError(message) }
        return output
    }
}
