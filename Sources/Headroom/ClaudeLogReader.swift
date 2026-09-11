import Foundation

/// Claude Code's own session transcripts: one JSONL file per session under
/// `<config dir>/projects/<encoded-path>/<session>.jsonl`.
///
/// This is the same data `ccusage` reads. Doing it here keeps the app free of Node and
/// of a network fetch on first run.
struct ClaudeLogReader: SpendReader {
    let account: ClaudeAccount

    var providers: [Provider] { [account.provider] }

    private var root: URL { account.root.appending(path: "projects") }

    func read(since: Date) -> SpendReading {
        guard let files = recentFiles(since: since) else { return SpendReading(failed: true) }

        // Claude Code writes the same assistant message several times while it streams.
        // Every copy carries the final input and cache figures, but the early ones carry
        // a partial `output_tokens` — often 1. Anthropic bills the finished response, so
        // the largest snapshot per message is the true one; keeping the first undercounts
        // output roughly threefold.
        var best: [String: (model: String, counts: TokenCounts)] = [:]

        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            text.enumerateLines { line, _ in
                guard let entry = decode(line),
                    parseISODate(entry["timestamp"] as? String).map({ $0 >= since }) == true,
                    let message = entry["message"] as? [String: Any],
                    let model = message["model"] as? String,
                    let usage = message["usage"] as? [String: Any]
                else { return }

                // Interrupts and local errors are recorded with this literal model name.
                guard model != "<synthetic>" else { return }

                // Both ids together: a sidechain replay can repeat a message id under a
                // new request id, and a line missing one still dedupes on the other.
                let key =
                    "\(message["id"] as? String ?? "")|\(entry["requestId"] as? String ?? "")"
                let counts = TokenCounts(
                    input: usage["input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0,
                    cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                    cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0)

                if let prior = best[key], prior.counts.output >= counts.output { return }
                best[key] = (model, counts)
            }
        }

        var byModel: [String: TokenCounts] = [:]
        for (model, counts) in best.values {
            byModel[model] = (byModel[model] ?? TokenCounts()) + counts
        }

        var spend = Spend()
        for (model, counts) in byModel {
            spend = spend
                + Spend(
                    counts: counts,
                    wouldCost: Pricing.cost(counts, provider: "anthropic", model: model))
        }
        return SpendReading(spend: spend.counts.total > 0 ? [account.provider: spend] : [:])
    }

    /// Every session ever recorded lives under this directory, so filtering by
    /// modification date is what keeps the poll cheap.
    ///
    /// `nil` means the walk itself failed, which is the only thing that counts as an
    /// unreadable source: a directory that was never created is an empty day, and a
    /// single file locked mid-write is skipped rather than failing the whole pass.
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

private func decode(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}
