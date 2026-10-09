import Foundation

/// Test-only entry point. Compile with the real readers and pricing, never the app.
@main
struct SpendProbe {
    static func main() throws {
        // Foundation on macOS uses CFFIXED_USER_HOME, not just HOME.
        guard let isolated = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              URL.homeDirectory.resolvingSymlinksInPath().path == URL(filePath: isolated).resolvingSymlinksInPath().path else {
            fatalError("Test home isolation failed")
        }
        let reader: any SpendReader = CommandLine.arguments[1] == "claude"
            ? ClaudeLogReader(account: ClaudeAccount(provider: .claude, configDir: CommandLine.arguments[2]))
            : PiReader()
        let reading = reader.read(since: .distantPast)
        var models: [String: Spend] = [:]
        for day in reading.days.values {
            for (model, spend) in day.models {
                models[model] = (models[model] ?? Spend()) + spend
            }
        }
        let rows = models.mapValues { spend -> [String: Any] in
            ["cost": spend.wouldCost, "incomplete": spend.isIncomplete,
             "input": spend.counts.input, "output": spend.counts.output,
             "cache_read": spend.counts.cacheRead, "cache_write": spend.counts.cacheWrite,
             "total": spend.counts.total]
        }
        let data = try JSONSerialization.data(withJSONObject: ["failed": reading.failed, "models": rows], options: .sortedKeys)
        print(String(decoding: data, as: UTF8.self))
    }
}
