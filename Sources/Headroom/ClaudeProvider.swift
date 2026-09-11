import CryptoKit
import Foundation

/// One Claude Code login. Claude Code keeps a separate Keychain entry and transcript
/// directory per `CLAUDE_CONFIG_DIR`, so each config directory is its own account with
/// its own quota.
struct ClaudeAccount: Sendable {
    let provider: Provider
    /// `CLAUDE_CONFIG_DIR`, or nil for the account on Claude Code's default `~/.claude`.
    let configDir: String?

    static let deeptune = ClaudeAccount(provider: .claude, configDir: nil)
    static let mercor = ClaudeAccount(
        provider: .claudeMercor, configDir: NSHomeDirectory() + "/.claude-mercor")

    var root: URL {
        configDir.map { URL(filePath: $0) } ?? URL.homeDirectory.appending(path: ".claude")
    }

    /// Whenever `CLAUDE_CONFIG_DIR` is set, Claude Code suffixes the service with the
    /// first 8 hex digits of the directory's SHA-256. That suffix is what stops a second
    /// login from overwriting the default one.
    var keychainService: String {
        guard let configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }
}

/// Reads the same endpoint Claude Code's own `/usage` panel uses.
///
/// Built off `limits[]` rather than the top-level keys (`five_hour`, `seven_day`,
/// `tangelo`, `nimbus_quill`, …): those are internal codenames that get added and
/// renamed between releases, whereas `limits[]` is the stable generic shape.
struct ClaudeProvider: UsageProvider {
    let account: ClaudeAccount

    var provider: Provider { account.provider }

    func fetch() async throws -> [Window] {
        let token = try Credentials.claudeAccessToken(for: account)
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
                id: "\(provider).\(kind)",
                provider: provider,
                label: label,
                percent: percent,
                resetsAt: resetsAt
            )
        }
    }
}
