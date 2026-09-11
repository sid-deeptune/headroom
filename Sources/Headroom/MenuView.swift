import Charts
import ServiceManagement
import SwiftUI

/// Every size in the panel is multiplied by this, so the panel grows as a whole and
/// keeps its proportions rather than having its parts retuned one by one.
let panelScale: CGFloat = 1.2

extension Font {
    /// `.caption` and `.caption2` at the panel's scale. macOS text styles have fixed
    /// sizes, so these stand in for them: both are 10pt, and `.caption2` is medium weight.
    static func panelCaption(design: Font.Design = .default) -> Font {
        .system(size: 10 * panelScale, design: design)
    }

    static func panelCaption2(design: Font.Design = .default) -> Font {
        .system(size: 10 * panelScale, weight: .medium, design: design)
    }
}

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
    var size: CGFloat = 12 * panelScale

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

    static func template(for provider: Provider) -> NSImage? {
        templates[provider.iconName]
    }

    /// Loaded once. `isTemplate` makes macOS ignore the artwork's own colour and
    /// tint it with the current foreground style, which is what keeps the marks
    /// legible in both light and dark mode.
    private static let templates: [String: NSImage] = {
        var loaded: [String: NSImage] = [:]
        for provider in Provider.allCases {
            if let bitmap = NSImage(named: provider.iconName) {
                // The status bar button lays out from the NSImage's intrinsic size, so
                // a 256pt source renders enormous there.
                let size = NSSize(width: 16, height: 16)
                // Redrawn at whatever size it is shown at. Handed the 256px bitmap
                // directly, SwiftUI shrinks it without smoothing, which breaks the
                // Claude mark's thin rays into loose pixels.
                let image = NSImage(size: size, flipped: false) { rect in
                    bitmap.draw(in: rect)
                    return true
                }
                image.isTemplate = true
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
        .frame(height: 4 * panelScale)
    }
}

struct WindowRow: View {
    let window: Window

    var body: some View {
        HStack(spacing: 8 * panelScale) {
            Text(window.label)
                .font(.panelCaption(design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62 * panelScale, alignment: .leading)
            Meter(percent: window.percent)
            Text("\(Int(window.percent.rounded()))%")
                .font(.panelCaption(design: .monospaced))
                .foregroundStyle(urgencyTint(window.percent))
                .frame(width: 32 * panelScale, alignment: .trailing)
            Text(timeUntil(window.resetsAt))
                .font(.panelCaption2())
                .foregroundStyle(.tertiary)
                .frame(width: 46 * panelScale, alignment: .trailing)
        }
    }
}

/// Takes `now` rather than reading the clock, so the panel's ticking timer is what
/// drives these strings forward while the menu is open.
func timeAgo(_ date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date)) / 60
    return minutes < 1 ? "just now" : "\(minutes)m ago"
}

/// "812k", "4.1M" — a token count is only ever read for its order of magnitude.
func formatTokens(_ tokens: Int) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return "\(tokens / 1_000)k" }
    return "\(tokens)"
}

/// Today's local activity for one provider, expandable.
///
/// Collapsed it shows input and output — the tokens that track real work — with the
/// cache figure subdued beneath them, because on any real day cache reads are two orders
/// of magnitude larger and would otherwise be all you read. Beneath rather than beside,
/// because a grid column is too narrow to hold all three on one line. Clicking opens the
/// split.
///
/// Deliberately says "would cost": every provider here is on a subscription, so this is
/// the API value of the work, not money that was charged.
struct SpendRow: View {
    let spend: Spend
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * panelScale) {
            Button {
                expanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 2 * panelScale) {
                    HStack(spacing: 4 * panelScale) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7 * panelScale, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("today")
                            .foregroundStyle(.tertiary)
                        Text("\(formatTokens(spend.counts.input)) in · \(formatTokens(spend.counts.output)) out")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("$\(spend.wouldCost, specifier: "%.2f")")
                            .foregroundStyle(.secondary)
                    }
                    if !expanded {
                        Text("\(formatTokens(spend.counts.cacheRead)) cached")
                            .foregroundStyle(.quaternary)
                            .padding(.leading, 11 * panelScale)
                    }
                }
                .font(.panelCaption2())
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if expanded {
                breakdown("Input", spend.counts.input, subdued: false)
                breakdown("Output", spend.counts.output, subdued: false)
                breakdown("Cache read", spend.counts.cacheRead, subdued: true)
                breakdown("Cache write", spend.counts.cacheWrite, subdued: true)
                Text("would cost at API prices")
                    .font(.panelCaption2())
                    .foregroundStyle(.quaternary)
                    .padding(.leading, 11 * panelScale)
            }
        }
    }

    private func breakdown(_ label: String, _ tokens: Int, subdued: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(formatTokens(tokens))
                .font(.panelCaption2(design: .monospaced))
        }
        .font(.panelCaption2())
        .foregroundStyle(subdued ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.secondary))
        .padding(.leading, 11 * panelScale)
    }
}

struct ProviderSection: View {
    let provider: Provider
    let snapshot: ProviderSnapshot
    let spend: Spend?
    let spendIsStale: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * panelScale) {
            HStack(spacing: 6 * panelScale) {
                ProviderIcon(provider: provider)
                Text(provider.rawValue)
                    .font(.panelCaption().weight(.semibold))
                Spacer()
                if snapshot.isStale, let updatedAt = snapshot.updatedAt {
                    Text("as of \(timeAgo(updatedAt, now: now))")
                        .font(.panelCaption2())
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)

            if snapshot.windows.isEmpty {
                // Only surface the error when there is nothing to fall back on.
                Text(snapshot.error ?? (snapshot.hasData ? "No active limits" : "Loading…"))
                    .font(.panelCaption2())
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(snapshot.windows) { WindowRow(window: $0) }
                    .opacity(snapshot.isStale ? 0.45 : 1)
            }

            if let spend, spend.counts.total > 0 {
                SpendRow(spend: spend)
                    .opacity(spendIsStale ? 0.45 : 1)
            }
        }
    }
}

/// One harness's last seven days, split by what each model's work would cost at API
/// prices. Cost rather than tokens: cache reads outnumber everything else by an order of
/// magnitude at a tenth of the price, so a token split mostly measures re-reads.
///
/// Monochrome on purpose. Colour means urgency everywhere else in the panel, so slices
/// are told apart by shade, darkest for the largest, and the legend keeps that order.
struct HarnessSection: View {
    let harness: Harness
    /// `nil` until the first read lands.
    let models: [String: Spend]?
    let isStale: Bool

    private struct Slice {
        let name: String
        let cost: Double
    }

    private static let shades: [Double] = [0.8, 0.58, 0.4, 0.26, 0.15]

    /// Past five, the shades stop being told apart, so the tail folds into "Other".
    private var slices: [Slice] {
        let ranked = (models ?? [:])
            .map { Slice(name: $0.key, cost: $0.value.wouldCost) }
            .filter { $0.cost > 0 }
            .sorted { $0.cost > $1.cost }
        guard ranked.count > Self.shades.count else { return ranked }
        let kept = Self.shades.count - 1
        return Array(ranked.prefix(kept))
            + [Slice(name: "Other", cost: ranked.dropFirst(kept).reduce(0) { $0 + $1.cost })]
    }

    var body: some View {
        let slices = self.slices
        let total = slices.reduce(0) { $0 + $1.cost }

        VStack(alignment: .leading, spacing: 8 * panelScale) {
            Text(harness.rawValue)
                .font(.panelCaption().weight(.semibold))

            if slices.isEmpty {
                Text(models == nil ? "Loading…" : "No work in the last 7 days")
                    .font(.panelCaption2())
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 5 * panelScale) {
                    ZStack {
                        Chart(Array(slices.enumerated()), id: \.element.name) { index, slice in
                            SectorMark(
                                angle: .value("Cost", slice.cost), innerRadius: .ratio(0.64),
                                angularInset: 1
                            )
                            .foregroundStyle(Color.primary.opacity(Self.shades[index]))
                        }
                        .chartLegend(.hidden)

                        VStack(spacing: 1 * panelScale) {
                            Text(total.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                                .font(.panelCaption(design: .monospaced).weight(.semibold))
                            Text("7 days")
                                .font(.panelCaption2())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 112 * panelScale)
                    .padding(.bottom, 4 * panelScale)

                    ForEach(Array(slices.enumerated()), id: \.element.name) { index, slice in
                        HStack(spacing: 6 * panelScale) {
                            RoundedRectangle(cornerRadius: 2 * panelScale)
                                .fill(Color.primary.opacity(Self.shades[index]))
                                .frame(width: 8 * panelScale, height: 8 * panelScale)
                            Text(slice.name)
                            Spacer()
                            Text(percentLabel(slice.cost / total * 100))
                        }
                        .font(.panelCaption(design: .monospaced))
                        .foregroundStyle(.secondary)
                    }
                }
                .opacity(isStale ? 0.45 : 1)
            }
        }
    }

    /// A sliver still has a slice, so it must not read as "0%".
    private func percentLabel(_ percent: Double) -> String {
        percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
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
                        .font(.system(size: 13 * panelScale))
                }
            }
            .frame(width: 22 * panelScale, height: 22 * panelScale)
            .background(
                hovering ? Color.primary.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 5 * panelScale))
        }
        .buttonStyle(.plain)
        .disabled(!store.canRefresh)
        .onHover { hovering = $0 && store.canRefresh }
        .help(store.isRefreshing ? "Refreshing…" : store.canRefresh ? "Refresh now" : "Just refreshed")
    }
}

enum PanelTab: String, CaseIterable {
    case providers = "Providers"
    case models = "Models"
}

struct MenuView: View {
    @ObservedObject var store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var tab = PanelTab.providers
    /// Called when a tab switch changes the panel's height, so the window can follow.
    var onResize: () -> Void = {}

    /// Ticks only while the panel is on screen. Without it the ages freeze at whatever
    /// they were when the menu opened, and the refresh button stays greyed out for the
    /// cooldown with no sign that it will come back.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Narrower than the old single column: at that width the grid ran to ~600pt, too
    /// wide to hang off the menu bar. `SpendRow` wraps its cache figure to fit.
    private let columnWidth: CGFloat = 216 * panelScale
    private let columnSpacing: CGFloat = 16 * panelScale

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * panelScale) {
            Picker("View", selection: $tab) {
                ForEach(PanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: tab) { onResize() }

            switch tab {
            case .providers:
                // Two to a row, top-aligned: sections differ in height (Claude can show a
                // per-model cap, a spend row can be expanded), and centring would misalign
                // the headers across a row.
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(columnWidth), spacing: columnSpacing, alignment: .top),
                        count: 2),
                    alignment: .leading, spacing: 14 * panelScale
                ) {
                    ForEach(Provider.allCases, id: \.self) { provider in
                        ProviderSection(
                            provider: provider, snapshot: store.states[provider] ?? ProviderSnapshot(),
                            spend: store.spend[provider],
                            spendIsStale: store.staleSpend.contains(provider), now: now)
                    }
                }
            case .models:
                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(Harness.allCases, id: \.self) { harness in
                        HarnessSection(
                            harness: harness, models: store.models[harness],
                            isStale: store.staleModels.contains(harness)
                        )
                        .frame(width: columnWidth, alignment: .topLeading)
                    }
                }
            }

            Divider()

            HStack {
                Text(store.updatedAt.map { "Updated \(timeAgo($0, now: now))" } ?? "Updating…")
                    .font(.panelCaption2())
                    .foregroundStyle(.tertiary)
                Spacer()
                RefreshButton(store: store)
            }

            HStack {
                Toggle("Open at Login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.panelCaption())
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled
                            ? SMAppService.mainApp.register()
                            : SMAppService.mainApp.unregister()
                    }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.panelCaption())
            }
        }
        .padding(14 * panelScale)
        .frame(width: columnWidth * 2 + columnSpacing + 28 * panelScale)
        .onReceive(tick) { now = $0 }
    }
}
