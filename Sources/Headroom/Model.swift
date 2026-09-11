import Foundation

/// Declaration order is menu order: the panel lays these out two to a row.
enum Provider: String, CaseIterable, Codable {
    case claude = "Claude Deeptune"
    case claudeMercor = "Claude Mercor"
    case codex = "Codex"
    case kimi = "Kimi"

    /// Brand mark in `Contents/Resources`, rasterized from simple-icons (CC0) by
    /// `bundle.sh`. Loaded as a template image so macOS tints it for light/dark.
    var iconName: String {
        switch self {
        case .claude, .claudeMercor: return "claude"
        case .codex: return "openai"
        case .kimi: return "kimi"
        }
    }

    /// Used when running the bare binary, which has no resource bundle.
    var fallbackSymbol: String {
        switch self {
        case .claude, .claudeMercor: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .kimi: return "moon.stars"
        }
    }
}

/// One quota window. Every provider reduces to a list of these.
struct Window: Identifiable, Codable {
    let id: String
    let provider: Provider
    /// Derived from the window length the API reports — never hardcoded, because
    /// window lengths differ per account and per provider.
    let label: String
    let percent: Double
    let resetsAt: Date?
}

/// Last known state for one provider.
///
/// Windows survive a failed refresh: a transient error dims the existing data rather
/// than destroying it, so a momentary 429 does not blank a provider that was fine a
/// minute ago.
struct ProviderSnapshot: Codable {
    var windows: [Window] = []
    var updatedAt: Date?
    var error: String?

    var hasData: Bool { updatedAt != nil }
    var isStale: Bool { error != nil && hasData }
}

protocol UsageProvider {
    var provider: Provider { get }
    func fetch() async throws -> [Window]
}

/// "5h", "7d" — from a raw window duration in seconds.
func windowLabel(seconds: Double) -> String {
    let hours = seconds / 3600
    if hours < 24 { return "\(Int(hours.rounded()))h" }
    return "\(Int((hours / 24).rounded()))d"
}

enum UsageError: LocalizedError {
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(429): return "Rate limited"
        case .http(401), .http(403): return "Signed out"
        case .http(let code): return "HTTP \(code)"
        case .badResponse: return "Unexpected response"
        }
    }
}

func fetchJSON(_ urlString: String, headers: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: urlString)!, timeoutInterval: 15)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw UsageError.http(status) }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw UsageError.badResponse
    }
    return json
}

/// Both Anthropic and Kimi return ISO-8601 with fractional seconds; Codex returns epoch.
///
/// The formatters are built once: a week of transcripts calls this tens of thousands of
/// times, and building them per call was most of that read's cost.
func parseISODate(_ string: String?) -> Date? {
    guard let string else { return nil }
    return isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
}

private let isoWithFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let isoPlain = ISO8601DateFormatter()
