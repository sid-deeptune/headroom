import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [Provider: ProviderState] = [:]
    @Published private(set) var updatedAt: Date?

    private let providers: [UsageProvider] = [ClaudeProvider(), CodexProvider(), KimiProvider()]
    private var isRefreshing = false

    /// Anthropic's endpoint is server-side rate limited and Claude Code itself throttles
    /// to one fetch per 5 minutes; the other two are cheaper but gain nothing from
    /// faster polling, since the shortest window is 5 hours long.
    private let pollInterval: TimeInterval = 300
    private let menuOpenFloor: TimeInterval = 60

    init() {
        for provider in Provider.allCases { states[provider] = .loading }
    }

    func start() {
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    /// Called when the menu opens, so the panel is current without hammering the APIs.
    func refreshIfStale() {
        guard let updatedAt, Date().timeIntervalSince(updatedAt) > menuOpenFloor else {
            if updatedAt == nil { Task { await refresh() } }
            return
        }
        Task { await refresh() }
    }

    /// Providers are fetched concurrently and fail independently — one signed-out
    /// provider must not blank out the other two.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: (Provider, ProviderState).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (provider.provider, .ok(try await provider.fetch()))
                    } catch {
                        return (provider.provider, .unavailable(error.localizedDescription))
                    }
                }
            }
            for await (provider, state) in group {
                states[provider] = state
            }
        }
        updatedAt = Date()
    }

    var allWindows: [Window] {
        Provider.allCases.flatMap { states[$0]?.windows ?? [] }
    }

    /// The window closest to biting — this is what the menu bar shows.
    var tightest: Window? {
        allWindows.max { $0.percent < $1.percent }
    }
}
