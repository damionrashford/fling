public enum SourceChoice: Equatable, Sendable {
    case none
    case single(Browser)
    /// Both browsers are running and nothing indicates which one is meant.
    /// The panel shows both rather than guessing.
    case ambiguous([Browser])
}

public struct BrowserResolver {

    public static func resolve(running: [Browser],
                               frontmostApp: String?,
                               lastUsed: Browser?) -> SourceChoice {
        // Preserve declaration order so the UI never reorders under the user.
        let live = Browser.allCases.filter { running.contains($0) }
        guard !live.isEmpty else { return .none }

        // 1. Frontmost browser wins.
        if let frontmostApp,
           let front = live.first(where: { $0.processName == frontmostApp }) {
            return .single(front)
        }
        // 2. Otherwise the browser last cast from, if still running.
        if let lastUsed, live.contains(lastUsed) { return .single(lastUsed) }
        // 3. Otherwise the only running browser.
        if live.count == 1 { return .single(live[0]) }
        // 4. Otherwise ask.
        return .ambiguous(live)
    }
}
