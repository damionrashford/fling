import Foundation

public enum CattParser {

    public static func parseStatus(_ output: String) -> CastStatus {
        var title: String?
        var elapsed: TimeInterval?
        var duration: TimeInterval?
        var volume: Int?
        var muted = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = line.trimmingCharacters(in: .whitespaces)

            // "Volume muted:" must be checked before "Volume:" — it is a prefix collision.
            if let v = value(after: "Volume muted:", in: l) {
                muted = v.lowercased() == "true"
            } else if let v = value(after: "Volume:", in: l) {
                volume = Int(v)
            } else if let v = value(after: "Title:", in: l) {
                title = v.isEmpty ? nil : v
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
                          volume: volume, muted: muted)
    }

    public static func parseScan(_ output: String) -> [DeviceInfo] {
        output.split(separator: "\n").compactMap { line -> DeviceInfo? in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("Scanning") else { return nil }

            // Format: "<ip> - <name> - <model>". The name may itself contain " - ",
            // so split off the first and last fields and rejoin the middle.
            let parts = l.components(separatedBy: " - ")
            guard parts.count >= 3 else { return nil }
            let ip = parts[0]
            let model = parts[parts.count - 1]
            let name = parts[1..<(parts.count - 1)].joined(separator: " - ")
            return DeviceInfo(ip: ip, name: name, model: model)
        }
    }

    public static func parseError(_ output: String) -> String? {
        if output.contains("RequestTimeout") || output.contains("timed out") {
            return "The TV did not respond. Make sure it is awake, then try again."
        }
        for line in output.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if let v = value(after: "Error:", in: l) { return v }
        }
        return nil
    }

    // MARK: - helpers

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
