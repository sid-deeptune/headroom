import Foundation

/// Claude Code's own session transcripts: one JSONL file per session under
/// `<config dir>/projects/<encoded-path>/<session>.jsonl`.
///
/// This is the same data `ccusage` reads. Doing it here keeps the app free of Node and
/// of a network fetch on first run.
struct ClaudeLogReader: SpendReader {
    let account: ClaudeAccount

    var providers: [Provider] { [account.provider] }

    let harness = Harness.claudeCode

    /// One cache per account, so pruning one account's finished sessions cannot drop
    /// the other's.
    private let cache = TranscriptCache()

    private var root: URL { account.root.appending(path: "projects") }

    func read(since: Date) -> SpendReading {
        guard let files = recentFiles(since: since) else { return SpendReading(failed: true) }

        var reading = SpendReading()
        for file in files {
            // A file touched inside the window can still hold lines from before it —
            // a long-running session picked up again today — so the days are filtered
            // rather than the files alone.
            for (day, byModel) in cache.days(of: file) where day >= since {
                var bucket = reading.days[day] ?? DaySpend()
                for (model, counts) in byModel {
                    let cost = Pricing.cost(counts, provider: "anthropic", model: model)
                    let spend = Spend(
                        counts: counts,
                        wouldCost: cost ?? 0, priceUnavailable: cost == nil)
                    bucket.spend[account.provider] =
                        (bucket.spend[account.provider] ?? Spend()) + spend
                    bucket.models[model] = (bucket.models[model] ?? Spend()) + spend
                }
                reading.days[day] = bucket
            }
        }
        cache.prune(to: files)
        return reading
    }

    /// Every session ever recorded lives under this directory, so filtering by
    /// modification date is what keeps the poll cheap.
    ///
    /// `nil` means the walk itself failed, which is the only thing that counts as an
    /// unreadable source: a directory that was never created is an empty day, and a
    /// single file locked mid-write is skipped rather than failing the whole pass.
    private func recentFiles(since: Date) -> [URL]? {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
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

/// Remembers what each transcript said, so a pass parses only what changed.
///
/// Transcripts are append-only and a finished session is never written again, so a file
/// whose size and modification date both match the last pass still holds the same
/// figures. On a normal day that leaves a megabyte or two to parse out of the week's
/// hundred-odd, which is the difference between the read costing seconds and costing
/// nothing.
///
/// A stale size against a fresh date, or the reverse, only costs one extra parse: the
/// pair after that parse is the one stored, and the next pass matches it.
private final class TranscriptCache: @unchecked Sendable {
    private struct Entry {
        let size: Int
        let modified: Date
        let days: [Date: [String: TokenCounts]]
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]

    /// One file's work by local day, parsed only if the file has changed since last time.
    func days(of file: URL) -> [Date: [String: TokenCounts]] {
        let stamp = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = stamp?.fileSize ?? -1
        let modified = stamp?.contentModificationDate ?? .distantPast

        lock.lock()
        let cached = entries[file]
        lock.unlock()
        if let cached, cached.size == size, cached.modified == modified { return cached.days }

        let days = parseTranscript(file)
        lock.lock()
        entries[file] = Entry(size: size, modified: modified, days: days)
        lock.unlock()
        return days
    }

    /// Forgets the sessions that have dropped out of the window being read, so the cache
    /// stays the size of the window rather than the size of the archive.
    func prune(to files: [URL]) {
        let live = Set(files)
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { live.contains($0.key) }
    }
}

/// One file's usage lines, deduplicated and bucketed by the local day they happened on.
///
/// Claude Code writes the same assistant message several times while it streams. Every
/// copy carries the final input and cache figures, but the early ones carry a partial
/// `output_tokens` — often 1. Anthropic bills the finished response, so the largest
/// snapshot per message is the true one; keeping the first undercounts output roughly
/// threefold.
///
/// Deduplicating within the file is enough: a message id never turns up in a second
/// session file.
private func parseTranscript(_ file: URL) -> [Date: [String: TokenCounts]] {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }

    // Held locally: `Calendar.current` copies the calendar on every access, and this
    // runs once per usage line.
    let calendar = Calendar.current
    var best: [String: (day: Date, model: String, counts: TokenCounts)] = [:]

    text.enumerateLines { line, _ in
        // Most lines are tool output and prompts. Ruling them out before the JSON
        // parse is what keeps a fresh file affordable to read.
        guard line.contains("\"usage\""), let entry = decode(line),
            let timestamp = parseISODate(entry["timestamp"] as? String),
            let message = entry["message"] as? [String: Any],
            let model = (message["model"] as? String).map(canonicalModel),
            let usage = message["usage"] as? [String: Any]
        else { return }

        // Interrupts and local errors are recorded with this literal model name.
        guard model != "<synthetic>" else { return }

        // Both ids together: a sidechain replay can repeat a message id under a
        // new request id, and a line missing one still dedupes on the other.
        let key = "\(message["id"] as? String ?? "")|\(entry["requestId"] as? String ?? "")"
        let counts = TokenCounts(
            input: usage["input_tokens"] as? Int ?? 0,
            output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0)

        if let prior = best[key], prior.counts.output >= counts.output { return }
        best[key] = (calendar.startOfDay(for: timestamp), model, counts)
    }

    var days: [Date: [String: TokenCounts]] = [:]
    for (day, model, counts) in best.values {
        days[day, default: [:]][model] = (days[day]?[model] ?? TokenCounts()) + counts
    }
    return days
}

private func decode(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}
