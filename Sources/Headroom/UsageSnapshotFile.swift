import Foundation

/// Mirrors each refresh to disk so other tools can read the numbers the menu already
/// shows, instead of calling the provider endpoints a second time. The MCP server in
/// `mcp/server.mjs` is the only consumer today, and it never touches the network.
///
/// Written even when a provider failed: the file carries each provider's own
/// `updatedAt` and `error`, so a reader can tell fresh data from stale data per
/// provider rather than trusting the top-level timestamp alone.
enum UsageSnapshotFile {
    static let url = URL.homeDirectory.appending(path: ".cache/headroom/usage.json")

    static func write(states: [Provider: ProviderSnapshot], updatedAt: Date) {
        var providers: [String: Any] = [:]
        for (provider, snapshot) in states {
            providers[provider.rawValue] = [
                "updatedAt": json(snapshot.updatedAt),
                "error": json(snapshot.error),
                "windows": snapshot.windows.map { window in
                    [
                        "id": window.id,
                        "label": window.label,
                        "percent": window.percent,
                        "resetsAt": json(window.resetsAt),
                    ]
                },
            ]
        }

        let root: [String: Any] = [
            "updatedAt": iso.string(from: updatedAt),
            "providers": providers,
        ]

        // Best effort: a menu bar app has no console, and a failed cache write must not
        // interfere with the UI, which already has the same data in memory.
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `.atomic` writes a temporary file and renames it, so a reader never sees a
        // partially written file.
        try? data.write(to: url, options: .atomic)
    }

    private static let iso = ISO8601DateFormatter()

    private static func json(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return iso.string(from: date)
    }

    private static func json(_ string: String?) -> Any {
        guard let string else { return NSNull() }
        return string
    }
}
