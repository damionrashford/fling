import Foundation

public protocol ProcessRunning {
    /// Runs `executable` with `args`, returning stdout and stderr combined.
    func run(_ executable: String, _ args: [String]) throws -> String
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8) ?? ""
    }
}
