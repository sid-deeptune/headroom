import ServiceManagement
import SwiftUI

/// Neutral below 60%, amber to 85%, red above.
///
/// Colour is reserved exclusively for urgency — provider identity is carried by name
/// and symbol, never hue. Starting neutral rather than green keeps colour meaningful:
/// if everything were green at rest, colour would stop carrying information.
func urgencyTint(_ percent: Double) -> Color {
    if percent >= 85 { return .red }
    if percent >= 60 { return .orange }
    return .secondary
}

func timeUntil(_ date: Date?) -> String {
    guard let date else { return "" }
    let total = Int(max(0, date.timeIntervalSinceNow))
    let days = total / 86400
    let hours = (total % 86400) / 3600
    let minutes = (total % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 12

    var body: some View {
        if let image = ProviderIcon.templates[provider.iconName] {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.fallbackSymbol)
        }
    }

    /// Loaded once. `isTemplate` makes macOS ignore the artwork's own colour and
    /// tint it with the current foreground style, which is what keeps the marks
    /// legible in both light and dark mode.
    private static let templates: [String: NSImage] = {
        var loaded: [String: NSImage] = [:]
        for provider in Provider.allCases {
            if let image = NSImage(named: provider.iconName) {
                image.isTemplate = true
                // MenuBarExtra's label lays out from the NSImage's intrinsic size and
                // ignores SwiftUI's .frame, so a 256pt source renders enormous there.
                image.size = NSSize(width: 16, height: 16)
                loaded[provider.iconName] = image
            }
        }
        return loaded
    }()
}

struct Meter: View {
    let percent: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(urgencyTint(percent))
                    .frame(width: geometry.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 4)
    }
}

struct WindowRow: View {
    let window: Window

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Meter(percent: window.percent)
            Text("\(Int(window.percent.rounded()))%")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(urgencyTint(window.percent))
                .frame(width: 32, alignment: .trailing)
            Text(timeUntil(window.resetsAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

/// Takes `now` rather than reading the clock, so the panel's ticking timer is what
/// drives these strings forward while the menu is open.
func timeAgo(_ date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date)) / 60
    return minutes < 1 ? "just now" : "\(minutes)m ago"
}

struct ProviderSection: View {
    let provider: Provider
    let snapshot: ProviderSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProviderIcon(provider: provider)
                Text(provider.rawValue)
                    .font(.caption.weight(.semibold))
                Spacer()
                if snapshot.isStale, let updatedAt = snapshot.updatedAt {
                    Text("as of \(timeAgo(updatedAt, now: now))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)

            if snapshot.windows.isEmpty {
                // Only surface the error when there is nothing to fall back on.
                Text(snapshot.error ?? (snapshot.hasData ? "No active limits" : "Loading…"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(snapshot.windows) { WindowRow(window: $0) }
                    .opacity(snapshot.isStale ? 0.45 : 1)
            }
        }
    }
}

/// The manual trigger. Background polling is deliberately slow, so this is the way to
/// force a fetch — which means it has to look like a button and say when it is busy.
/// `.borderless` gave neither, which is why it read as broken.
struct RefreshButton: View {
    @ObservedObject var store: UsageStore
    @State private var hovering = false

    var body: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            Group {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 22, height: 22)
            .background(
                hovering ? Color.primary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!store.canRefresh)
        .onHover { hovering = $0 && store.canRefresh }
        .help(store.isRefreshing ? "Refreshing…" : store.canRefresh ? "Refresh now" : "Just refreshed")
    }
}

struct MenuView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Ticks only while the panel is on screen. Without it the ages freeze at whatever
    /// they were when the menu opened, and the refresh button stays greyed out for the
    /// cooldown with no sign that it will come back.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Provider.allCases, id: \.self) { provider in
                ProviderSection(
                    provider: provider, snapshot: store.states[provider] ?? ProviderSnapshot(),
                    now: now)
            }

            Divider()

            HStack {
                Text(store.updatedAt.map { "Updated \(timeAgo($0, now: now))" } ?? "Updating…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                RefreshButton(store: store)
            }

            HStack {
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled
                            ? SMAppService.mainApp.register()
                            : SMAppService.mainApp.unregister()
                    }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onReceive(tick) { now = $0 }
    }
}
