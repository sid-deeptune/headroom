import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [Provider: ProviderSnapshot] = [:]
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    /// Today's local activity, keyed by the subscription it bills to.
    @Published private(set) var spend: [Provider: Spend] = [:]

    private let providers: [UsageProvider] = [ClaudeProvider(), CodexProvider(), KimiProvider()]

    /// Anthropic's endpoint is server-side rate limited, and opening the menu used to
    /// fetch as well, which is what pushed it into 429s. The shortest window we track
    /// is 5 hours long, so a slow background poll loses nothing; the refresh button is
    /// there for when you want a number right now.
    private let pollInterval: TimeInterval = 900

    /// Stops a burst of clicks from undoing the point of the slow poll.
    private let manualCooldown: TimeInterval = 30

    /// Spend comes off local files rather than an endpoint, so it can poll far more
    /// often than the network. Not faster than this, though: a heavy day leaves tens of
    /// megabytes of transcript to re-parse on every pass.
    private let spendInterval: TimeInterval = 300

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
        Task {
            await Pricing.refreshIfStale()
            while !Task.isCancelled {
                await readSpend()
                try? await Task.sleep(for: .seconds(spendInterval))
            }
        }
    }

    /// Reads every tool's local log. Parsing runs off the main actor because the
    /// transcripts can run to tens of megabytes.
    private func readSpend() async {
        let since = Calendar.current.startOfDay(for: Date())
        let read = await Task.detached {
            var total: [Provider: Spend] = [:]
            for reader in spendReaders {
                for (provider, spend) in reader.read(since: since) {
                    total[provider] = (total[provider] ?? Spend()) + spend
                }
            }
            return total
        }.value

        // Merged, not replaced: a reader that fails — an unreadable file, a database
        // mid-write — returns nothing, and the last known figure is better than a row
        // that vanishes.
        for (provider, spend) in read { self.spend[provider] = spend }
    }

    /// Drives the refresh button's enabled state, so a click that would be dropped is
    /// visibly unavailable instead of silently doing nothing.
    var canRefresh: Bool {
        guard !isRefreshing else { return false }
        guard let updatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) >= manualCooldown
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
        let now = Date()
        updatedAt = now
        UsageSnapshotFile.write(states: states, updatedAt: now)
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
