import Foundation

public enum CattParser {

    public static func parseStatus(_ output: String) -> CastStatus {
        var title: String?
        var elapsed: TimeInterval?
        var duration: TimeInterval?
        var volume: Int?
        var muted = false
        var state = PlaybackState.unknown

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = line.trimmingCharacters(in: .whitespaces)

            // "Volume muted:" must be checked before "Volume:" — it is a prefix collision.
            if let v = value(after: "Volume muted:", in: l) {
                muted = v.lowercased() == "true"
            } else if let v = value(after: "Volume:", in: l) {
                volume = Int(v)
            } else if let v = value(after: "Title:", in: l) {
                title = v.isEmpty ? nil : v
            } else if let v = value(after: "State:", in: l) {
                state = PlaybackState(catt: v)
            } else if let v = value(after: "Time:", in: l) {
                // "00:00:01 / 00:00:15 (11%)"
                let parts = v.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 {
                    elapsed = seconds(parts[0])
                    duration = seconds(String(parts[1].prefix(while: { $0 != "(" }))
                        .trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return CastStatus(title: title, elapsed: elapsed, duration: duration,
                          volume: volume, muted: muted, state: state)
    }

    public static func parseScan(_ output: String) -> [DeviceInfo] {
        output.split(separator: "\n").compactMap { line -> DeviceInfo? in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("Scanning") else { return nil }

            // Format: "<ip> - <name> - <model>". The name may itself contain
            // " - ", so take the first and last fields and rejoin the middle.
            let parts = l.components(separatedBy: " - ")
            guard parts.count >= 3 else { return nil }
            let ip = parts[0]
            let model = parts[parts.count - 1]
            let name = parts[1..<(parts.count - 1)].joined(separator: " - ")
            return DeviceInfo(ip: ip, name: name, model: model)
        }
    }

    /// Line-aware over a finished run: a media title containing "timed out"
    /// must never register as an error, so timeout markers count only on
    /// non-Title lines (tracebacks, pychromecast noise) and on stderr.
    public static func parseError(stdout: String, stderr: String = "",
                                  exitCode: Int32 = 0) -> String? {
        let stdoutLines = lines(stdout)
        let stderrLines = lines(stderr)

        // catt prints its own "Error: ..." messages to stdout and still exits
        // 0, so these are checked regardless of status.
        for l in stdoutLines + stderrLines {
            if let v = value(after: "Error:", in: l), !v.isEmpty { return v }
        }

        let timeoutMarkers = ["RequestTimeout", "timed out"]
        let diagnostic = stdoutLines.filter { !$0.hasPrefix("Title:") } + stderrLines
        if diagnostic.contains(where: { l in timeoutMarkers.contains(where: l.contains) }) {
            return "The TV did not respond. Make sure it is awake, then try again."
        }

        // A failed run with no recognizable message still must not pass as
        // success; the last stderr line is the most specific thing available.
        if exitCode != 0 {
            return stderrLines.last ?? "catt failed (exit \(exitCode))"
        }
        return nil
    }

    /// Merged-output convenience for callers without a structured result.
    public static func parseError(_ output: String) -> String? {
        parseError(stdout: output)
    }

    // MARK: - helpers

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// "HH:MM:SS" or "MM:SS" → seconds.
    private static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
