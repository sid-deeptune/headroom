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
/// It is not what you were charged: every provider here is on a subscription. The
/// dollar figure is a value estimate, so
/// the UI labels it "would cost" rather than "spent".
struct Spend: Codable {
    var counts = TokenCounts()
    var wouldCost: Double = 0
    // Optional so snapshots from older builds still decode.
    var priceUnavailable: Bool? = nil

    var isIncomplete: Bool { priceUnavailable == true }

    static func + (lhs: Spend, rhs: Spend) -> Spend {
        Spend(counts: lhs.counts + rhs.counts, wouldCost: lhs.wouldCost + rhs.wouldCost,
              priceUnavailable: lhs.isIncomplete || rhs.isIncomplete)
    }
}

/// One local day's work, both ways the panel splits it.
struct DaySpend {
    var spend: [Provider: Spend] = [:]
    /// The same work keyed by `canonicalModel`, for the Models tab.
    var models: [String: Spend] = [:]

    static func + (lhs: DaySpend, rhs: DaySpend) -> DaySpend {
        DaySpend(
            spend: lhs.spend.merging(rhs.spend) { $0 + $1 },
            models: lhs.models.merging(rhs.models) { $0 + $1 })
    }
}

/// What one pass over a tool's records saw, in buckets of one local day.
///
/// Days rather than a single total, so one pass serves both tabs: the Providers tab
/// sums today alone, the Models tab sums the whole window.
///
/// `failed` separates "the source could not be read" from "the source was read and it
/// says nothing happened today". Without that split a quiet provider keeps yesterday's
/// figures under a label that says today.
struct SpendReading {
    /// Keyed by the start of the local day. Days before the requested start are absent.
    var days: [Date: DaySpend] = [:]
    var failed = false
}

/// The tool the work was done in. The Models tab splits by this rather than by
/// subscription, because one harness draws on several.
enum Harness: String, CaseIterable, Codable {
    case claudeCode = "Claude Code"
    case pi = "pi"
}

/// Reads a tool's own local records. No network, no quota.
protocol SpendReader: Sendable {
    /// Every provider this reader speaks for, whether or not it found rows for one.
    /// A provider absent from a successful reading is genuinely at zero.
    var providers: [Provider] { get }

    var harness: Harness { get }

    /// Every day from `since` onward, where `since` is the start of a local day.
    func read(since: Date) -> SpendReading
}

/// One list, shared by the store and by `--probe`.
let spendReaders: [SpendReader] = [
    ClaudeLogReader(account: .deeptune), ClaudeLogReader(account: .mercor), PiReader(),
]

/// The Models tab covers today and the six local days before it.
///
/// Whole days rather than a rolling week: a slice would otherwise shrink between polls
/// as a session aged past the edge, and whole days let the per-file cache serve the
/// window as a plain sum of buckets.
let modelWindowDays = 7

/// The start of the oldest local day a window of `days` covers, today included.
func windowStart(days: Int, now: Date = Date()) -> Date {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
}

/// One name per model, so a variant neither splits a model into two slices nor misses
/// its price. `claude-opus-5[1m]` and `gpt-5.6-sol-900k` are the base model with a
/// larger context, a dated id is its alias, and Kimi's K3 turns up as both `k3`
/// and `kimi-k3`.
func canonicalModel(_ id: String) -> String {
    let base = id.replacing(#/\[\w+\]$|-\d+k$|-\d{8}$/#, with: "")
    return base == "k3" ? "kimi-k3" : base
}
