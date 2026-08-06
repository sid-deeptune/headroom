import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [Provider: ProviderSnapshot] = [:]
    @Published private(set) var updatedAt: Date?

    private let providers: [UsageProvider] = [ClaudeProvider(), CodexProvider(), KimiProvider()]
    private var isRefreshing = false

    /// Anthropic's endpoint is server-side rate limited and Claude Code itself throttles
    /// to one fetch per 5 minutes; the other two are cheaper but gain nothing from
    /// faster polling, since the shortest window is 5 hours long.
    private let pollInterval: TimeInterval = 300
    private let menuOpenFloor: TimeInterval = 60

    init() {
        for provider in Provider.allCases { states[provider] = ProviderSnapshot() }
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

        await withTaskGroup(of: (Provider, Result<[Window], Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (provider.provider, .success(try await Self.fetchWithRetry(provider)))
                    } catch {
                        return (provider.provider, .failure(error))
                    }
                }
            }
            for await (provider, result) in group {
                var snapshot = states[provider] ?? ProviderSnapshot()
                switch result {
                case .success(let windows):
                    snapshot.windows = windows
                    snapshot.updatedAt = Date()
                    snapshot.error = nil
                case .failure(let error):
                    snapshot.error = error.localizedDescription
                }
                states[provider] = snapshot
            }
        }
        updatedAt = Date()
    }

    /// Retries rate limiting and server errors rather than waiting out the poll
    /// interval — a 429 that clears in seconds should not blank a provider for
    /// five minutes. Other failures (signed out, unreadable credentials) are
    /// returned immediately, since retrying them would not help.
    private static func fetchWithRetry(_ provider: UsageProvider) async throws -> [Window] {
        for delay in [Duration.seconds(20), .seconds(60)] {
            do {
                return try await provider.fetch()
            } catch let error where isTransient(error) {
                try? await Task.sleep(for: delay)
            }
        }
        return try await provider.fetch()
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard case UsageError.http(let code) = error else { return false }
        return code == 429 || (500...599).contains(code)
    }

    var allWindows: [Window] {
        Provider.allCases.flatMap { states[$0]?.windows ?? [] }
    }

    /// The window closest to biting — this is what the menu bar shows.
    var tightest: Window? {
        allWindows.max { $0.percent < $1.percent }
    }
}
