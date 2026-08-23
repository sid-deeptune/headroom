import Foundation
import SQLite3

/// OpenCode's local database. Codex and Kimi are both used through OpenCode here, so
/// this one reader covers both.
///
/// OpenCode writes no JSONL — every assistant turn is a JSON blob in the `message`
/// table, carrying its own token counts, `providerID` and `modelID`. Its `cost` field
/// is ignored: it reads 0 on subscription authentication, which is every provider the
/// app tracks.
struct OpenCodeReader: SpendReader {
    let providers: [Provider] = [.claude, .codex, .kimi]

    private let database = URL.homeDirectory
        .appending(path: ".local/share/opencode/opencode.db")

    /// `time_created` is milliseconds since the epoch. Reasoning tokens are stored
    /// apart from output — the row's own `total` only balances once both are added —
    /// and they bill at the output rate, so they are folded into output here.
    private static let query = """
        SELECT json_extract(data, '$.providerID'),
               json_extract(data, '$.modelID'),
               SUM(COALESCE(json_extract(data, '$.tokens.input'), 0)),
               SUM(COALESCE(json_extract(data, '$.tokens.output'), 0))
                 + SUM(COALESCE(json_extract(data, '$.tokens.reasoning'), 0)),
               SUM(COALESCE(json_extract(data, '$.tokens.cache.read'), 0)),
               SUM(COALESCE(json_extract(data, '$.tokens.cache.write'), 0))
        FROM message
        WHERE time_created >= ?
          AND json_extract(data, '$.role') = 'assistant'
        GROUP BY 1, 2
        """

    func read(since: Date) -> SpendReading {
        // No database is not a failure: it is what an unused OpenCode looks like.
        guard FileManager.default.fileExists(atPath: database.path) else { return SpendReading() }

        // Read-only, so a poll can never disturb a running OpenCode session.
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
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))

        var spend: [Provider: Spend] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            defer { step = sqlite3_step(statement) }
            guard let providerID = text(statement, 0), let provider = map(providerID) else {
                continue
            }
            let tokens = TokenCounts(
                input: Int(sqlite3_column_int64(statement, 2)),
                output: Int(sqlite3_column_int64(statement, 3)),
                cacheRead: Int(sqlite3_column_int64(statement, 4)),
                cacheWrite: Int(sqlite3_column_int64(statement, 5)))

            let cost = Pricing.cost(
                tokens, provider: providerID, model: text(statement, 1) ?? "")
            spend[provider] = (spend[provider] ?? Spend()) + Spend(counts: tokens, wouldCost: cost)
        }

        // A run that stopped short — the database busy under a live OpenCode session —
        // has counted only part of the day, so it is reported as a failure rather than
        // as a smaller day.
        guard step == SQLITE_DONE else { return SpendReading(failed: true) }
        return SpendReading(spend: spend)
    }

    /// OpenCode names providers; the menu bar groups by the subscription they bill to.
    /// A provider that is not one of the three tracked here is left out rather than
    /// folded into a neighbour.
    private func map(_ providerID: String) -> Provider? {
        switch providerID {
        case "anthropic": return .claude
        case "openai": return .codex
        case "kimi-for-coding", "moonshotai": return .kimi
        default: return nil
        }
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }
}
