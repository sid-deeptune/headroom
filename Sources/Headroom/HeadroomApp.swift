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

/// Borderless so the panel matches what `MenuBarExtra(.window)` drew. `NSPopover` was
/// the obvious substitute but it is not the same UI: it adds an anchor arrow and drops
/// the body below it, which moves the panel away from the menu bar.
private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let panel = MenuPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: true)
    private var statusItem: StatusItemController?
    private var storeChanges: AnyCancellable?
    private var outsideClicks: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        buildPanel()

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
    /// across six windows — "23%" of what? — so the title keeps the window's own label.
    /// The brand mark carries the provider, which is why the name is not spelled out:
    /// width is the scarce resource here. macOS drops a status item it cannot fit, and
    /// gives no signal that it did, so the item that survives a full menu bar is the
    /// narrow one.
    private func draw(_ button: NSStatusBarButton) {
        if let window = store.tightest {
            button.image = ProviderIcon.template(for: window.provider)
            button.title = " \(window.label) \(Int(window.percent.rounded()))%"
            button.imagePosition = .imageLeading
        } else {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.50percent",
                accessibilityDescription: "Headroom")
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func buildPanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let content = NSHostingView(rootView: MenuView(store: store))
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panel.isVisible ? closePanel() : openPanel(under: sender)
    }

    private func openPanel(under button: NSStatusBarButton) {
        guard let host = button.window, let screen = host.screen else { return }

        let size = panel.contentView?.fittingSize ?? .zero
        panel.setContentSize(size)

        // Centred on the item but kept on screen, and hung directly off the menu bar —
        // `visibleFrame` already excludes it, so its top edge is the anchor.
        let anchor = host.convertToScreen(button.convert(button.bounds, to: nil))
        let x = min(
            max(anchor.midX - size.width / 2, screen.visibleFrame.minX + 8),
            screen.visibleFrame.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: screen.visibleFrame.maxY - size.height))
        panel.makeKeyAndOrderFront(nil)

        // A click on the item itself has to fall through to the button's own action,
        // or closing here and reopening there leaves the panel stuck open.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.itemContainsPointer() else { return }
                self.closePanel()
            }
        }
    }

    private func itemContainsPointer() -> Bool {
        guard let button = statusItem?.item?.button, let host = button.window else { return false }
        return host.convertToScreen(button.convert(button.bounds, to: nil))
            .contains(NSEvent.mouseLocation)
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
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

        let since = Calendar.current.startOfDay(for: Date())
        for reader in spendReaders {
            for (provider, spend) in reader.read(since: since).spend {
                let counts = spend.counts
                print(
                    "\(provider.rawValue) today  in \(counts.input)  out \(counts.output)  "
                        + "cache r \(counts.cacheRead) w \(counts.cacheWrite)  "
                        + String(format: "$%.2f", spend.wouldCost))
            }
        }
        done.signal()
    }
    done.wait()
    exit(0)
}
