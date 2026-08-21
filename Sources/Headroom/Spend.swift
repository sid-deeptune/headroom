import Foundation

/// Token counts as both log formats report them, kept split so the menu can show where
/// the volume actually went. Cache reads dominate every real day, so folding them into
/// one total would hide the input and output figures that track real work.
struct TokenCounts {
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
/// why OpenCode records its own `cost` as 0. The dollar figure is a value estimate, so
/// the UI labels it "would cost" rather than "spent".
struct Spend {
    var counts = TokenCounts()
    var wouldCost: Double = 0

    static func + (lhs: Spend, rhs: Spend) -> Spend {
        Spend(counts: lhs.counts + rhs.counts, wouldCost: lhs.wouldCost + rhs.wouldCost)
    }
}

/// Reads a tool's own local records. No network, no quota.
protocol SpendReader: Sendable {
    func read(since: Date) -> [Provider: Spend]
}

/// One list, shared by the store and by `--probe`.
let spendReaders: [SpendReader] = [ClaudeLogReader(), OpenCodeReader()]
