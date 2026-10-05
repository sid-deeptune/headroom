import Foundation

/// pi's session logs: one JSONL file per session under
/// `~/.pi/agent/sessions/<encoded-path>/<session>.jsonl`. Codex and Kimi are both used
/// through pi here, so this one reader covers both.
///
/// Each assistant message carries its provider, model and final token counts once, so
/// lines need no deduplication. Its `cost` is ignored, as it is for every source here:
/// the figure is recomputed from models.dev prices so all tabs price work the same way.
struct PiReader: SpendReader {
    let providers: [Provider] = [.codex, .kimi]
    let harness = Harness.pi

    private let root = URL.homeDirectory.appending(path: ".pi/agent/sessions")

    /// Parses every file touched inside the window on each pass, with no cache: the whole
    /// archive is a few megabytes. Add a size-and-date cache like `ClaudeLogReader`'s if
    /// that grows.
    func read(since: Date) -> SpendReading {
        guard let files = recentFiles(since: since) else { return SpendReading(failed: true) }

        // Held locally: `Calendar.current` copies the calendar on every access.
        let calendar = Calendar.current
        var reading = SpendReading()
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            text.enumerateLines { line, _ in
                guard line.contains("\"usage\""), let data = line.data(using: .utf8),
                    let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                    let message = entry["message"] as? [String: Any],
                    let usage = message["usage"] as? [String: Any],
                    let (provider, pricedAs) = map(message["provider"] as? String ?? ""),
                    let model = (message["model"] as? String).map(canonicalModel),
                    let milliseconds = message["timestamp"] as? Double
                else { return }
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: milliseconds / 1000))
                guard day >= since else { return }

                // `output` already includes reasoning tokens.
                let tokens = TokenCounts(
                    input: usage["input"] as? Int ?? 0,
                    output: usage["output"] as? Int ?? 0,
                    cacheRead: usage["cacheRead"] as? Int ?? 0,
                    cacheWrite: usage["cacheWrite"] as? Int ?? 0)
                let cost = Pricing.cost(tokens, provider: pricedAs, model: model)
                let spend = Spend(
                    counts: tokens, wouldCost: cost ?? 0, priceUnavailable: cost == nil)
                var bucket = reading.days[day] ?? DaySpend()
                bucket.spend[provider] = (bucket.spend[provider] ?? Spend()) + spend
                bucket.models[model] = (bucket.models[model] ?? Spend()) + spend
                reading.days[day] = bucket
            }
        }
        return reading
    }

    /// pi names providers its own way. Each maps to the subscription the menu bar groups
    /// by, and to the provider id models.dev prices it under. `openai` is Sign in with
    /// ChatGPT, which draws on the same subscription as `openai-codex`. A provider that
    /// is not one tracked here is left out rather than folded into a neighbour.
    private func map(_ provider: String) -> (Provider, String)? {
        switch provider {
        case "openai", "openai-codex": return (.codex, "openai")
        case "kimi-coding": return (.kimi, "kimi-for-coding")
        default: return nil
        }
    }

    /// Same contract as `ClaudeLogReader.recentFiles`: `nil` only when the walk itself
    /// fails, and an absent directory is an empty week.
    private func recentFiles(since: Date) -> [URL]? {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return nil }

        return walker.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            guard let modified, modified >= since else { return nil }
            return url
        }
    }
}
