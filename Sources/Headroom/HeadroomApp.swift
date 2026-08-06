import SwiftUI

@main
struct HeadroomApp: App {
    @StateObject private var store = UsageStore()

    init() {
        if CommandLine.arguments.contains("--probe") { probe() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            MenuBarLabel(store: store)
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Names the window that is closest to biting. A bare percentage would be ambiguous
/// across six windows — "23%" of what? — so the title always identifies which one.
/// The brand mark carries the provider, which is why the name is not spelled out.
struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        if let window = store.tightest {
            HStack(spacing: 4) {
                ProviderIcon(provider: window.provider)
                Text("\(window.provider.rawValue) \(window.label) \(Int(window.percent.rounded()))%")
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }
}

/// `Headroom --probe` prints live provider output and exits. A menu bar app has no
/// console, so this is how we see what the providers actually return.
private func probe() -> Never {
    let providers: [UsageProvider] = [ClaudeProvider(), CodexProvider(), KimiProvider()]
    let done = DispatchSemaphore(value: 0)
    Task {
        for provider in providers {
            do {
                for window in try await provider.fetch() {
                    let reset = window.resetsAt?.formatted(date: .abbreviated, time: .shortened)
                    print("\(window.provider.rawValue) \(window.label)  \(window.percent)%  resets \(reset ?? "—")")
                }
            } catch {
                print("\(provider.provider.rawValue): \(error.localizedDescription)")
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}
