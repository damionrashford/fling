import Foundation

public struct CattError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// `@unchecked Sendable`: both stored properties are `let` and the production
/// runner is a stateless struct. Instances are handed to detached tasks so
/// blocking subprocess calls stay off the main actor.
public final class CattClient: @unchecked Sendable {
    private let executable: String
    private let runner: ProcessRunning

    public init(executable: String, runner: ProcessRunning = SystemProcessRunner()) {
        self.executable = executable
        self.runner = runner
    }

    /// GUI apps do not inherit the shell's PATH, so the known install
    /// locations are probed explicitly.
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

    public func cast(_ url: String, kind: CastKind, device: String,
                     seekTo: TimeInterval? = nil) throws {
        var opts: [String] = []
        switch kind {
        case .directMedia:
            opts.append("-f")
        case .youtube, .extractableSite:
            break
        case .notCastable(let reason):
            throw CattError(reason)
        }
        if let seekTo, seekTo >= 1 {
            opts += ["-t", String(Int(seekTo.rounded()))]
        }
        _ = try invoke(["-d", device, "cast"] + opts + [url])
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

    /// Powers the TV screen on: the cast protocol has no power command, but
    /// launching a receiver app fires HDMI-CEC "One Touch Play". The launch
    /// result is ignored because DashCast's ack can outlive pychromecast's
    /// 10 s wait; the follow-up `stop` is the signal the TV answered.
    public func wake(device: String, settle: TimeInterval = 1.0) throws {
        _ = try? invoke(["-d", device, "cast_site", "https://example.com"])
        Thread.sleep(forTimeInterval: settle)
        _ = try invoke(["-d", device, "stop"])
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
