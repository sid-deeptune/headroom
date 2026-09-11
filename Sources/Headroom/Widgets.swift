import Charts
import SwiftUI
import WidgetKit

/// The panel's two tabs as desktop widgets, so the figures are on screen without a click.
///
/// Runs in the extension `bundle.sh` builds from this same binary. It draws what the app
/// last saved to `PanelSnapshot`.
struct HeadroomWidgets: WidgetBundle {
    var body: some Widget {
        ProvidersWidget()
        ModelsWidget()
    }
}

struct ProvidersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PanelTab.providers.rawValue, provider: PanelTimeline()) { entry in
            WidgetFrame { ProvidersWidgetView(entry: entry, family: $0) }
        }
        .configurationDisplayName("Providers")
        .description("Quota used on each subscription, and when it resets.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ModelsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PanelTab.models.rawValue, provider: PanelTimeline()) { entry in
            WidgetFrame { ModelsWidgetView(entry: entry, family: $0) }
        }
        .configurationDisplayName("Models")
        .description("The last 7 days of work by model, at API prices.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct PanelEntry: TimelineEntry {
    let date: Date
    let snapshot: PanelSnapshot
}

struct PanelTimeline: TimelineProvider {
    func placeholder(in context: Context) -> PanelEntry {
        PanelEntry(date: Date(), snapshot: PanelSnapshot.read() ?? PanelSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PanelEntry) -> Void) {
        completion(placeholder(in: context))
    }

    /// An entry a minute for half an hour, so the reset countdowns and the age of the
    /// figures keep moving. WidgetKit draws the entries ahead of time, which is why the
    /// views count from `entry.date` rather than the clock. The figures themselves change
    /// only when the app saves a read and asks for a reload.
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PanelEntry>) -> Void) {
        let snapshot = PanelSnapshot.read() ?? PanelSnapshot()
        let minute = Calendar.current.dateInterval(of: .minute, for: Date())?.start ?? Date()
        let entries = (0..<30).map {
            PanelEntry(date: minute.addingTimeInterval(Double($0) * 60), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// Hands a layout its size, which a widget can only read from inside a view, and gives
/// it the standard widget background.
private struct WidgetFrame<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content

    var body: some View {
        content(family)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

/// Medium is the panel's two-column grid with the meters alone. Large has room for the
/// reset times and today's spend, but not for two columns of them, so it stacks.
struct ProvidersWidgetView: View {
    let entry: PanelEntry
    let family: WidgetFamily

    var body: some View {
        if family == .systemMedium {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 12 * panelScale, alignment: .top), count: 2),
                alignment: .leading, spacing: 8 * panelScale
            ) {
                ForEach(Provider.allCases, id: \.self) {
                    WidgetProviderSection(provider: $0, entry: entry, compact: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10 * panelScale) {
                ForEach(Provider.allCases, id: \.self) {
                    WidgetProviderSection(provider: $0, entry: entry, compact: false)
                }
                Spacer(minLength: 0)
                UpdatedLabel(entry: entry)
            }
        }
    }
}

/// `ProviderSection` for the desktop. The panel's spend row opens on a click, which a
/// widget cannot take, so today's figures sit on one line instead.
struct WidgetProviderSection: View {
    let provider: Provider
    let entry: PanelEntry
    /// Meters only, for a half-width column.
    let compact: Bool

    var body: some View {
        let state = entry.snapshot.states[provider] ?? ProviderSnapshot()

        VStack(alignment: .leading, spacing: 4 * panelScale) {
            HStack(spacing: 6 * panelScale) {
                ProviderIcon(provider: provider)
                Text(provider.rawValue)
                    .font(.panelCaption().weight(.semibold))
                if !compact, state.isStale, let updatedAt = state.updatedAt {
                    Spacer()
                    Text("as of \(timeAgo(updatedAt, now: entry.date))")
                        .font(.panelCaption2())
                        .foregroundStyle(.tertiary)
                }
            }

            if state.windows.isEmpty {
                Text(state.error ?? (state.hasData ? "No active limits" : "Loading…"))
                    .font(.panelCaption2())
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(state.windows) { window in
                    if compact {
                        CompactWindowRow(window: window)
                    } else {
                        WindowRow(window: window, now: entry.date)
                    }
                }
                .opacity(state.isStale ? 0.45 : 1)
            }

            if !compact, let spend = entry.snapshot.spend[provider], spend.counts.total > 0 {
                HStack(spacing: 4 * panelScale) {
                    Text("today")
                        .foregroundStyle(.tertiary)
                    Text("\(formatTokens(spend.counts.input)) in · \(formatTokens(spend.counts.output)) out")
                        .foregroundStyle(.secondary)
                    Text("· \(formatTokens(spend.counts.cacheRead)) cached")
                        .foregroundStyle(.quaternary)
                    Spacer()
                    Text("$\(spend.wouldCost, specifier: "%.2f")")
                        .foregroundStyle(.secondary)
                }
                .font(.panelCaption2())
                .lineLimit(1)
                .opacity(entry.snapshot.staleSpend.contains(provider) ? 0.45 : 1)
            }
        }
    }
}

/// `WindowRow` without the reset time, which a half-width column has no room for.
struct CompactWindowRow: View {
    let window: Window

    var body: some View {
        HStack(spacing: 6 * panelScale) {
            Text(window.label)
                .foregroundStyle(.secondary)
                .frame(width: 50 * panelScale, alignment: .leading)
            Meter(percent: window.percent)
            Text("\(Int(window.percent.rounded()))%")
                .foregroundStyle(urgencyTint(window.percent))
                .frame(width: 26 * panelScale, alignment: .trailing)
        }
        .font(.panelCaption(design: .monospaced))
    }
}

/// Large is the panel's Models tab. Medium is too short for a donut above its legend, so
/// a small one sits beside each harness's name instead.
struct ModelsWidgetView: View {
    let entry: PanelEntry
    let family: WidgetFamily

    var body: some View {
        let snapshot = entry.snapshot

        VStack(alignment: .leading, spacing: 10 * panelScale) {
            HStack(alignment: .top, spacing: 14 * panelScale) {
                ForEach(Harness.allCases, id: \.self) { harness in
                    let models = snapshot.models[harness]
                    let isStale = snapshot.staleModels.contains(harness)
                    Group {
                        if family == .systemMedium {
                            CompactHarnessSection(harness: harness, models: models, isStale: isStale)
                        } else {
                            HarnessSection(harness: harness, models: models, isStale: isStale)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if family != .systemMedium {
                Spacer(minLength: 0)
                UpdatedLabel(entry: entry)
            }
        }
    }
}

/// `HarnessSection` for a short row: the same donut and legend, with the donut shrunk to
/// sit beside the name and the total.
struct CompactHarnessSection: View {
    let harness: Harness
    let models: [String: Spend]?
    let isStale: Bool

    var body: some View {
        let slices = HarnessSection.slices(of: models)
        let total = slices.reduce(0) { $0 + $1.cost }

        VStack(alignment: .leading, spacing: 5 * panelScale) {
            HStack(spacing: 6 * panelScale) {
                if !slices.isEmpty {
                    HarnessSection.donut(slices)
                        .frame(width: 26 * panelScale, height: 26 * panelScale)
                }
                VStack(alignment: .leading, spacing: 1 * panelScale) {
                    Text(harness.rawValue)
                        .font(.panelCaption().weight(.semibold))
                    Text(
                        slices.isEmpty
                            ? (models == nil ? "Loading…" : "No work in the last 7 days")
                            : total.formatted(.currency(code: "USD").precision(.fractionLength(0)))
                                + " · 7 days"
                    )
                    .font(.panelCaption2())
                    .foregroundStyle(.tertiary)
                }
            }
            HarnessSection.legend(slices)
        }
        .opacity(isStale ? 0.45 : 1)
    }
}

/// The panel's "Updated" line. It matters more on the desktop: if the app is not running,
/// this is the only sign that the figures have stopped moving.
struct UpdatedLabel: View {
    let entry: PanelEntry

    var body: some View {
        Text(entry.snapshot.updatedAt.map { "Updated \(timeAgo($0, now: entry.date))" } ?? "Updating…")
            .font(.panelCaption2())
            .foregroundStyle(.tertiary)
    }
}
