import Foundation

/// Published API prices in dollars per million tokens.
struct ModelPrice {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
}

/// The price table, from models.dev.
///
/// Keys are models.dev's provider and model ids; readers map their log's names onto
/// them. A copy ships in the bundle so a first run with no network still prices
/// correctly; the download only ever replaces a table that already works.
enum Pricing {
    /// Only the providers whose logs are read. The full document is 4 MB; this is 4 KB.
    private static let providers = ["anthropic", "openai", "kimi-for-coding", "moonshotai"]
    private static let source = "https://models.dev/api.json"
    private static let maxAge: TimeInterval = 86400
    @MainActor private static var refreshing = false

    private static let cache = URL.homeDirectory
        .appending(path: "Library/Application Support/Headroom/prices.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: [String: ModelPrice]] = load()

    /// models.dev prices every `kimi-for-coding` model at zero, because that plan is a
    /// subscription rather than a metered endpoint. The same weights are sold by the
    /// hour under `moonshotai`, so that is what the value estimate uses.
    private static let metered = [
        "kimi-for-coding/kimi-k3": ("moonshotai", "kimi-k3")
    ]

    /// `provider` and `model` as the log recorded them. An unpriced model still has its
    /// tokens counted — a missing price must not silently drop usage.
    static func cost(_ counts: TokenCounts, provider: String, model: String) -> Double? {
        let (provider, model) = metered["\(provider)/\(model)"] ?? (provider, model)
        lock.lock()
        defer { lock.unlock() }
        guard let price = table[provider]?[model] else { return nil }
        return (Double(counts.input) * price.input
            + Double(counts.output) * price.output
            + Double(counts.cacheRead) * price.cacheRead
            + Double(counts.cacheWrite - counts.cacheWrite1h) * price.cacheWrite
            // models.dev lists only the 5-minute write price; Anthropic charges a 1-hour
            // write at 2x input.
            + Double(counts.cacheWrite1h) * 2 * price.input) / 1_000_000
    }

    /// Checked during usage polling; manual refresh bypasses the daily age limit.
    @MainActor static func refreshIfStale(force: Bool = false) async {
        guard !refreshing else { return }
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate.map { Date().timeIntervalSince($0) }
        if !force, let age, age < maxAge { return }
        refreshing = true
        defer { refreshing = false }

        let request = URLRequest(url: URL(string: source)!, timeoutInterval: 30)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let trimmed = trim(data)
        else { return }

        try? FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? trimmed.write(to: cache, options: .atomic)

        setTable(parse(trimmed))
    }

    /// Kept synchronous: taking a lock across a suspension point is an error under the
    /// Swift 6 language mode.
    private static func setTable(_ new: [String: [String: ModelPrice]]) {
        lock.lock()
        defer { lock.unlock() }
        table = merging(table, with: new)
    }

    /// models.dev nests each price under `models.<id>.cost`; the stored shape is flat.
    private static func trim(_ data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: [String: Any]] = [:]
        for provider in providers {
            let models = (root[provider] as? [String: Any])?["models"] as? [String: Any] ?? [:]
            var prices: [String: Any] = [:]
            for (id, model) in models {
                if let cost = (model as? [String: Any])?["cost"] { prices[id] = cost }
            }
            if !prices.isEmpty { out[provider] = prices }
        }
        guard !out.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: out, options: .sortedKeys)
    }

    private static func merging(
        _ base: [String: [String: ModelPrice]], with newer: [String: [String: ModelPrice]]
    ) -> [String: [String: ModelPrice]] {
        base.merging(newer) { $0.merging($1) { _, price in price } }
    }

    /// Keep entries from both sources, with the newer file winning overlapping IDs.
    private static func load() -> [String: [String: ModelPrice]] {
        let bundle = Bundle.main.url(forResource: "Prices", withExtension: "json")
        let sources = [bundle, cache].compactMap { $0 }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhs < rhs
        }
        return sources.reduce(into: [:]) { result, url in
            if let data = try? Data(contentsOf: url) {
                result = merging(result, with: parse(data))
            }
        }
    }

    private static func parse(_ data: Data) -> [String: [String: ModelPrice]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var table: [String: [String: ModelPrice]] = [:]
        for (provider, models) in root {
            guard let models = models as? [String: Any] else { continue }
            var prices: [String: ModelPrice] = [:]
            for (id, cost) in models {
                guard let cost = cost as? [String: Any] else { continue }
                guard let input = cost["input"] as? Double,
                    let output = cost["output"] as? Double,
                    input.isFinite, output.isFinite, input >= 0, output >= 0
                else { continue }
                let cacheRead = cost["cache_read"] as? Double ?? input
                let cacheWrite = cost["cache_write"] as? Double ?? input
                guard cacheRead.isFinite, cacheWrite.isFinite, cacheRead >= 0, cacheWrite >= 0
                else { continue }
                prices[id] = ModelPrice(
                    input: input,
                    output: output,
                    // Not every model reports cache prices; falling back to the input
                    // price keeps a cached-heavy session from reading as free.
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite)
            }
            if !prices.isEmpty { table[provider] = prices }
        }
        return table
    }
}
