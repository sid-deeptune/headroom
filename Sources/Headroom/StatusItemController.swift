import AppKit

/// Owns the menu bar item.
///
/// `MenuBarExtra` hands back no reference to its status item, so when the item goes
/// missing there is nothing to inspect and nothing to rebuild — the only cure is
/// relaunching, which a menu bar app cannot ask for once its icon is gone. Holding the
/// item here is what makes that recoverable.
@MainActor
final class StatusItemController {
    /// Readable so the label can be redrawn as usage changes, and so the item can be
    /// torn down from outside to exercise recovery.
    private(set) var item: NSStatusItem?

    /// Re-run on every rebuild, so a recovered item comes back with its icon and
    /// action rather than as a blank slot.
    private let configure: (NSStatusItem) -> Void

    private let watchdog: TimeInterval
    private let tolerance: TimeInterval
    private var timer: Timer?

    /// The watchdog is the only guarantee. The notifications below cover the cases we
    /// can name and make those instant, but the fault that prompted this was never
    /// reproduced, so nothing may announce it — the poll is what catches the rest.
    init(
        watchdog: TimeInterval = 60,
        tolerance: TimeInterval = 30,
        configure: @escaping (NSStatusItem) -> Void
    ) {
        self.watchdog = watchdog
        self.tolerance = tolerance
        self.configure = configure
    }

    /// `window.isVisible` is the only property that flips when an item leaves the bar.
    /// `NSStatusItem.isVisible` tracks only the explicit setter, and `button.window`
    /// stays non-nil after removal, so neither can stand in for this.
    var isAlive: Bool { item?.button?.window?.isVisible == true }

    func start() {
        rebuild()

        // Tolerance lets macOS coalesce this with wakeups it is already making, which
        // is what keeps a repeating timer off the energy budget.
        let timer = Timer.scheduledTimer(withTimeInterval: watchdog, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.ensureAlive() }
        }
        timer.tolerance = tolerance
        self.timer = timer

        // `willSleep` fires before the disruption and so repairs ahead of it; the wake
        // pair covers a sleep that started before we were watching. Screen parameter
        // changes do not fire on sleep at all — they cover display reconfiguration.
        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ] {
            workspace.addObserver(self, selector: #selector(recover), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(recover),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func recover() {
        ensureAlive()
    }

    @discardableResult
    func ensureAlive() -> Bool {
        guard !isAlive else { return false }
        if let item { NSStatusBar.system.removeStatusItem(item) }
        rebuild()
        return true
    }

    private func rebuild() {
        let new = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configure(new)
        item = new
    }
}
