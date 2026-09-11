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
/// the copy Claude Code / Hermes hold and log the user out of their actual tools.
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

    // MARK: Hermes-managed credentials

    struct OpenAICredentials {
        let accessToken: String
        let accountId: String
    }

    /// Re-read on every poll so Hermes's own token refreshes are picked up for free.
    static func openAI() throws -> OpenAICredentials {
        let path = URL.homeDirectory.appending(path: ".hermes/auth.json")
        guard let data = try? Data(contentsOf: path),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CredentialError.missing("Hermes auth.json unreadable")
        }
        let pool = root["credential_pool"] as? [String: Any]
        let entries = pool?["openai-codex"] as? [[String: Any]] ?? []
        guard let token = entries.lazy.compactMap({ $0["access_token"] as? String }).first else {
            throw CredentialError.missing("Codex not signed in via Hermes")
        }
        return OpenAICredentials(accessToken: token, accountId: chatGPTAccountId(token) ?? "")
    }

    /// Hermes stores no account id beside the token, but the token carries one: a
    /// ChatGPT access token is a JWT with the id under OpenAI's auth claim.
    private static func chatGPTAccountId(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        else { return nil }
        return auth["chatgpt_account_id"] as? String
    }

    /// Hermes's credential pool holds only a fingerprint of the Kimi key; the key itself
    /// is in the environment file Hermes loads it from.
    static func kimiKey() throws -> String {
        let path = URL.homeDirectory.appending(path: ".hermes/.env")
        let prefix = "KIMI_API_KEY="
        let lines = (try? String(contentsOf: path, encoding: .utf8))?.split(whereSeparator: \.isNewline) ?? []
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else {
            throw CredentialError.missing("Kimi key not found in Hermes")
        }
        let key = line.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard !key.isEmpty else { throw CredentialError.missing("Kimi key not found in Hermes") }
        return key
    }
}
