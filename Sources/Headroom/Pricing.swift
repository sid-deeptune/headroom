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
/// models.dev is where OpenCode gets its own provider and model ids, so its keys match
/// what the logs contain and no name mapping is needed. A copy ships in the bundle so
/// a first run with no network still prices correctly; the download only ever replaces
/// a table that already works.
enum Pricing {
    /// Only the providers whose logs are read. The full document is 4 MB; this is 4 KB.
    private static let providers = ["anthropic", "openai", "kimi-for-coding", "moonshotai"]
    private static let source = "https://models.dev/api.json"
    private static let maxAge: TimeInterval = 7 * 86400

    private static let cache = URL.homeDirectory
        .appending(path: "Library/Application Support/Headroom/prices.json")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: [String: ModelPrice]] = load()

    /// models.dev prices every `kimi-for-coding` model at zero, because that plan is a
    /// subscription rather than a metered endpoint. The same weights are sold by the
    /// hour under `moonshotai`, so that is what the value estimate uses.
    private static let metered = [
        "kimi-for-coding/k3": ("moonshotai", "kimi-k3"),
        "kimi-for-coding/k3-256k": ("moonshotai", "kimi-k3"),
        "kimi-for-coding/kimi-for-coding": ("moonshotai", "kimi-k2.7-code"),
        "kimi-for-coding/kimi-for-coding-highspeed": ("moonshotai", "kimi-k2.7-code-highspeed"),
    ]

    /// `provider` and `model` as the log recorded them. An unpriced model still has its
    /// tokens counted — a missing price must not silently drop usage.
    static func cost(_ counts: TokenCounts, provider: String, model: String) -> Double {
        let (provider, model) = metered["\(provider)/\(model)"] ?? (provider, model)
        lock.lock()
        defer { lock.unlock() }
        guard let price = table[provider]?[model] else { return 0 }
        return (Double(counts.input) * price.input
            + Double(counts.output) * price.output
            + Double(counts.cacheRead) * price.cacheRead
            + Double(counts.cacheWrite) * price.cacheWrite) / 1_000_000
    }

    /// Called on launch. Prices change over months, so a weekly re-download of 4 MB is
    /// cheaper than the machinery to avoid it.
    static func refreshIfStale() async {
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate.map { Date().timeIntervalSince($0) }
        if let age, age < maxAge { return }

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
        table = new
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

    /// Cache first, then the bundled copy. A cache written by an older build that no
    /// longer parses simply loses to the bundle.
    private static func load() -> [String: [String: ModelPrice]] {
        // A cache holding only empty provider maps must lose to the bundle, or a
        // truncated download would price everything at zero forever.
        if let data = try? Data(contentsOf: cache) {
            let parsed = parse(data)
            if parsed.values.contains(where: { !$0.isEmpty }) { return parsed }
        }
        guard let url = Bundle.main.url(forResource: "Prices", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return [:] }
        return parse(data)
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
                let input = cost["input"] as? Double ?? 0
                prices[id] = ModelPrice(
                    input: input,
                    output: cost["output"] as? Double ?? 0,
                    // Not every model reports cache prices; falling back to the input
                    // price keeps a cached-heavy session from reading as free.
                    cacheRead: cost["cache_read"] as? Double ?? input,
                    cacheWrite: cost["cache_write"] as? Double ?? input)
            }
            if !prices.isEmpty { table[provider] = prices }
        }
        return table
    }
}
