import SwiftUI
import FlingKit

struct OnboardingView: View {
    let missing: [Browser]
    let onRecheck: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Fling needs permission")
                .font(.system(size: 13, weight: .semibold))

            Text("macOS asks separately for each app. Fling needs \(list) so it can read the address of your frontmost tab.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(missing) { browser in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(browser.displayName)
                }
                .font(.system(size: 12))
            }

            HStack(spacing: 8) {
                // Re-probing is what triggers the system consent dialog per app.
                Button("Grant access") { Task { await onRecheck() } }
                Button("Open Settings") { PermissionProbe.openAutomationSettings() }
            }
            .font(.system(size: 11.5))
        }
        .padding(14)
        .frame(width: 260)
    }

    private var list: String {
        let names = missing.map(\.displayName)
        guard names.count > 1 else { return names.first ?? "your browser" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
