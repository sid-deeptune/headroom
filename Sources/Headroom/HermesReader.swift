import Foundation
import SQLite3

/// Hermes's session store. Codex and Kimi are both used through Hermes here, so this
/// one reader covers both.
///
/// Every model a session calls gets a row in `session_model_usage` with its own token
/// counts and the provider it billed to. Its `estimated_cost_usd` is ignored: it reads 0
/// on subscription authentication, which is every provider the app tracks.
struct HermesReader: SpendReader {
    let providers: [Provider] = [.claude, .codex, .kimi]
    let harness = Harness.hermes

    private let database = URL.homeDirectory.appending(path: ".hermes/state.db")

    /// Rows total a whole session, so a session counts in full on the day it last ran.
    /// Hermes sessions last hours, not days, so that barely moves the window's edge.
    /// `last_seen` is seconds since the epoch. Reasoning tokens bill at the output rate,
    /// so they are folded into output here.
    ///
    /// SQLite buckets the day rather than Swift, because the grouping has to happen
    /// inside the aggregate. It yields "2026-09-19", which `localDay` turns back into
    /// that day's local midnight.
    private static let query = """
        SELECT billing_provider, model,
               date(last_seen, 'unixepoch', 'localtime'),
               SUM(input_tokens),
               SUM(output_tokens) + SUM(reasoning_tokens),
               SUM(cache_read_tokens),
               SUM(cache_write_tokens)
        FROM session_model_usage
        WHERE last_seen >= ?
        GROUP BY 1, 2, 3
        """

    func read(since: Date) -> SpendReading {
        // No database is not a failure: it is what an unused Hermes looks like.
        guard FileManager.default.fileExists(atPath: database.path) else { return SpendReading() }

        // Read-only, so a poll can never disturb a running Hermes session.
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else {
            sqlite3_close(handle)
            return SpendReading(failed: true)
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, Self.query, -1, &statement, nil) == SQLITE_OK else {
            return SpendReading(failed: true)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)

        var reading = SpendReading()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let billing = text(statement, 0), let (provider, pricedAs) = map(billing),
                let model = text(statement, 1).map(canonicalModel),
                let day = text(statement, 2).flatMap(localDay.date(from:))
            else { continue }
            let tokens = TokenCounts(
                input: Int(sqlite3_column_int64(statement, 3)),
                output: Int(sqlite3_column_int64(statement, 4)),
                cacheRead: Int(sqlite3_column_int64(statement, 5)),
                cacheWrite: Int(sqlite3_column_int64(statement, 6)))

            let spend = Spend(
                counts: tokens, wouldCost: Pricing.cost(tokens, provider: pricedAs, model: model))
            var bucket = reading.days[day] ?? DaySpend()
            bucket.spend[provider] = (bucket.spend[provider] ?? Spend()) + spend
            bucket.models[model] = (bucket.models[model] ?? Spend()) + spend
            reading.days[day] = bucket
        }

        // A run that stopped short — the database busy under a live Hermes session —
        // has counted only part of the window, so it is reported as a failure rather
        // than as a quieter one.
        guard step == SQLITE_DONE else { return SpendReading(failed: true) }
        return reading
    }

    /// Hermes names billing providers its own way. Each maps to the subscription the
    /// menu bar groups by, and to the provider id models.dev prices it under. A provider
    /// that is not one tracked here is left out rather than folded into a neighbour.
    private func map(_ billing: String) -> (Provider, String)? {
        switch billing {
        case "anthropic": return (.claude, "anthropic")
        case "openai-codex": return (.codex, "openai")
        case "kimi-coding": return (.kimi, "kimi-for-coding")
        default: return nil
        }
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}

/// Turns SQLite's "2026-09-19" back into that day's local midnight. Built once, like
/// the ISO formatters, since it is called per row.
private let localDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()
