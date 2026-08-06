import Foundation

/// Reads the same endpoint Claude Code's own `/usage` panel uses.
///
/// Built off `limits[]` rather than the top-level keys (`five_hour`, `seven_day`,
/// `tangelo`, `nimbus_quill`, …): those are internal codenames that get added and
/// renamed between releases, whereas `limits[]` is the stable generic shape.
struct ClaudeProvider: UsageProvider {
    let provider = Provider.claude

    func fetch() async throws -> [Window] {
        let token = try Credentials.claudeAccessToken()
        let json = try await fetchJSON(
            "https://api.anthropic.com/api/oauth/usage",
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
            ]
        )

        guard let limits = json["limits"] as? [[String: Any]] else { throw UsageError.badResponse }

        return limits.compactMap { limit -> Window? in
            guard let kind = limit["kind"] as? String,
                let percent = limit["percent"] as? Double
            else { return nil }

            let resetsAt = parseISODate(limit["resets_at"] as? String)

            let label: String
            switch kind {
            case "session":
                label = "5h"
            case "weekly_all":
                label = "7d"
            case "weekly_scoped":
                // Per-model cap. Skip when dormant — an unused scoped cap has no
                // reset time and reads as noise next to the real windows.
                guard percent > 0 || resetsAt != nil else { return nil }
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = model?["display_name"] as? String
                label = name.map { "7d \($0)" } ?? "7d"
            default:
                return nil
            }

            return Window(
                id: "claude.\(kind)",
                provider: .claude,
                label: label,
                percent: percent,
                resetsAt: resetsAt
            )
        }
    }
}
