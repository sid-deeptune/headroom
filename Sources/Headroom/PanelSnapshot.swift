import Foundation

/// What the menu panel shows, saved after every read so the desktop widgets draw the
/// same figures without reading a provider or a log themselves.
///
/// A file in the home folder rather than an App Group container, because App Group
/// containers are tied to a signing team and `bundle.sh` signs ad hoc. The widget
/// extension is sandboxed, so its entitlements open this one folder to it, read-only.
struct PanelSnapshot: Codable {
    var states: [Provider: ProviderSnapshot] = [:]
    var updatedAt: Date?
    var spend: [Provider: Spend] = [:]
    var staleSpend: Set<Provider> = []
    var models: [Harness: [String: Spend]] = [:]
    var staleModels: Set<Harness> = []

    /// The real home folder, from the user database: inside the sandbox,
    /// `URL.homeDirectory` is the extension's own container.
    static let url = URL(filePath: String(cString: getpwuid(getuid()).pointee.pw_dir))
        .appending(path: ".cache/headroom/panel.json")

    /// Best effort, like `UsageSnapshotFile`: the panel already has the same data in memory.
    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }

    static func read() -> PanelSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PanelSnapshot.self, from: data)
    }
}
