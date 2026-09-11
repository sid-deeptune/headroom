import Foundation

enum CredentialError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let what): return what
        }
    }
}

/// Reads credentials that other tools own. Never writes them back: both Anthropic
/// and OpenAI rotate the refresh token on use, so refreshing here would invalidate
/// the copy Claude Code / OpenCode hold and log the user out of their actual tools.
enum Credentials {

    // MARK: Claude Code

    /// Keychain is the live store; `.credentials.json` in the config directory is a stale
    /// plaintext fallback Claude Code only writes when Keychain is unavailable.
    ///
    /// Shells out to `/usr/bin/security` rather than using the in-process Keychain API:
    /// the item is ACL'd to Claude Code, and an ad-hoc-signed app gets a new identity on
    /// every rebuild, so an in-process read would re-prompt after each build.
    static func claudeAccessToken(for account: ClaudeAccount) throws -> String {
        if let json = try? runSecurity(service: account.keychainService),
            let token = claudeToken(from: json)
        {
            return token
        }
        let fallback = account.root.appending(path: ".credentials.json")
        if let data = try? Data(contentsOf: fallback), let token = claudeToken(from: data) {
            return token
        }
        throw CredentialError.missing("Claude Code not signed in")
    }

    private static func runSecurity(service: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-a", NSUserName(), "-w", "-s", service,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CredentialError.missing("Keychain read failed")
        }
        return data
    }

    private static func claudeToken(from data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["accessToken"] as? String
    }

    // MARK: OpenCode-managed credentials

    struct OpenAICredentials {
        let accessToken: String
        let accountId: String
    }

    static func openAI() throws -> OpenAICredentials {
        let openai = try openCodeAuth()["openai"] as? [String: Any]
        guard let token = openai?["access"] as? String else {
            throw CredentialError.missing("Codex not signed in via OpenCode")
        }
        return OpenAICredentials(
            accessToken: token,
            accountId: openai?["accountId"] as? String ?? ""
        )
    }

    static func kimiKey() throws -> String {
        let kimi = try openCodeAuth()["kimi-for-coding"] as? [String: Any]
        guard let key = kimi?["key"] as? String else {
            throw CredentialError.missing("Kimi key not found in OpenCode")
        }
        return key
    }

    /// Re-read on every poll so OpenCode's own token refreshes are picked up for free.
    private static func openCodeAuth() throws -> [String: Any] {
        let path = URL.homeDirectory.appending(path: ".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: path),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CredentialError.missing("OpenCode auth.json unreadable")
        }
        return root
    }
}
