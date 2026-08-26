import AppKit

public enum ClipboardReader {
    public static func read() -> String? {
        NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

public extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
