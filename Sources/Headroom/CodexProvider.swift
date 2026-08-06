import Foundation

/// The endpoint Codex's own `/status` view reads.
///
/// Deliberately ignores `additional_rate_limits[]` (per-model caps like Spark) —
/// not on this plan's usage path, and the least stable part of the response.
struct CodexProvider: UsageProvider {
    let provider = Provider.codex

    func fetch() async throws -> [Window] {
        let credentials = try Credentials.openAI()
        let json = try await fetchJSON(
            "https://chatgpt.com/backend-api/wham/usage",
            headers: [
                "Authorization": "Bearer \(credentials.accessToken)",
                "ChatGPT-Account-Id": credentials.accountId,
            ]
        )

        guard let rateLimit = json["rate_limit"] as? [String: Any] else {
            throw UsageError.badResponse
        }

        // Do not assume primary is the short window: on some plans primary is weekly
        // and secondary is absent entirely. The label comes from the reported length.
        return ["primary_window", "secondary_window"].compactMap { key -> Window? in
            guard let window = rateLimit[key] as? [String: Any],
                let percent = window["used_percent"] as? Double
            else { return nil }

            let seconds = window["limit_window_seconds"] as? Double
            let resetsAt = (window["reset_at"] as? Double).map(Date.init(timeIntervalSince1970:))

            return Window(
                id: "codex.\(key)",
                provider: .codex,
                label: seconds.map { windowLabel(seconds: $0) } ?? "—",
                percent: percent,
                resetsAt: resetsAt
            )
        }
    }
}
