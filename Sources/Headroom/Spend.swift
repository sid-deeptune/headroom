import Foundation

/// Token counts as both log formats report them, kept split so the menu can show where
/// the volume actually went. Cache reads dominate every real day, so folding them into
/// one total would hide the input and output figures that track real work.
struct TokenCounts: Codable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite)
    }
}

/// What a provider's local logs say was sent, and what the same work would have cost at
/// published API prices.
///
/// It is not what you were charged: every provider here is on a subscription, which is
/// why Hermes records its own `cost` as 0. The dollar figure is a value estimate, so
/// the UI labels it "would cost" rather than "spent".
struct Spend: Codable {
    var counts = TokenCounts()
    var wouldCost: Double = 0

    static func + (lhs: Spend, rhs: Spend) -> Spend {
        Spend(counts: lhs.counts + rhs.counts, wouldCost: lhs.wouldCost + rhs.wouldCost)
    }
}

/// What one pass over a tool's records saw.
///
/// `failed` separates "the source could not be read" from "the source was read and it
/// says nothing happened today". Without that split a quiet provider keeps yesterday's
/// figures under a label that says today.
struct SpendReading {
    var spend: [Provider: Spend] = [:]
    /// The same work keyed by `canonicalModel`, for the Models tab.
    var models: [String: Spend] = [:]
    var failed = false
}

/// The tool the work was done in. The Models tab splits by this rather than by
/// subscription, because one harness draws on several.
enum Harness: String, CaseIterable, Codable {
    case claudeCode = "Claude Code"
    case hermes = "Hermes"
}

/// Reads a tool's own local records. No network, no quota.
protocol SpendReader: Sendable {
    /// Every provider this reader speaks for, whether or not it found rows for one.
    /// A provider absent from a successful reading is genuinely at zero.
    var providers: [Provider] { get }

    var harness: Harness { get }

    func read(since: Date) -> SpendReading
}

/// One list, shared by the store and by `--probe`.
let spendReaders: [SpendReader] = [
    ClaudeLogReader(account: .deeptune), ClaudeLogReader(account: .mercor), HermesReader(),
]

/// The Models tab looks back as far as the longest quota window.
let modelWindow: TimeInterval = 7 * 86400

/// One name per model, so a variant neither splits a model into two slices nor misses
/// its price. `claude-opus-5[1m]` and `gpt-5.6-sol-900k` are the base model with a
/// larger context, a dated id is its alias, and Hermes records Kimi's K3 as both
/// `k3` and `kimi-k3`.
func canonicalModel(_ id: String) -> String {
    let base = id.replacing(#/\[\w+\]$|-\d+k$|-\d{8}$/#, with: "")
    return base == "k3" ? "kimi-k3" : base
}
