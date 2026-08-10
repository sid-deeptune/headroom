import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--probe") { probe() }
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let popover = NSPopover()
    private var statusItem: StatusItemController?
    private var storeChanges: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(store: store))

        let statusItem = StatusItemController { [weak self] item in
            guard let self, let button = item.button else { return }
            button.target = self
            button.action = #selector(self.togglePanel)
            self.draw(button)
        }
        statusItem.start()
        self.statusItem = statusItem

        // `objectWillChange` fires before the new value lands, so the redraw waits a
        // runloop turn to read it.
        storeChanges =
            store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let button = self?.statusItem?.item?.button else { return }
                self?.draw(button)
            }

        store.start()
    }

    /// Names the window that is closest to biting. A bare percentage would be ambiguous
    /// across six windows — "23%" of what? — so the title always identifies which one.
    /// The brand mark carries the provider, which is why the name is not spelled out.
    private func draw(_ button: NSStatusBarButton) {
        if let window = store.tightest {
            button.image = ProviderIcon.template(for: window.provider)
            button.title =
                " \(window.provider.rawValue) \(window.label) \(Int(window.percent.rounded()))%"
            button.imagePosition = .imageLeading
        } else {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.50percent",
                accessibilityDescription: "Headroom")
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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
