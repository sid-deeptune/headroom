import Foundation

/// Kimi for Coding subscription usage. Undocumented endpoint (the vendor's own doc
/// link 404s), so every field is treated as optional.
///
/// Quantities come back as strings. An exhausted window returns `used` but omits
/// `remaining`, so usage must support both response shapes.
struct KimiProvider: UsageProvider {
    let provider = Provider.kimi

    func fetch() async throws -> [Window] {
        let key = try Credentials.kimiKey()
        let json = try await fetchJSON(
            "https://api.kimi.com/coding/v1/usages",
            headers: ["Authorization": "Bearer \(key)"]
        )

        var windows: [Window] = []

        // Rolling short window(s): length is reported as duration + time unit.
        for (index, entry) in (json["limits"] as? [[String: Any]] ?? []).enumerated() {
            guard let detail = entry["detail"] as? [String: Any],
                let percent = percentUsed(detail)
            else { continue }

            let window = entry["window"] as? [String: Any]
            let duration = number(window?["duration"]) ?? 0
            let unit = window?["timeUnit"] as? String ?? ""
            let seconds = duration * secondsPerUnit(unit)

            windows.append(
                Window(
                    id: "kimi.limit\(index)",
                    provider: .kimi,
                    label: seconds > 0 ? windowLabel(seconds: seconds) : "—",
                    percent: percent,
                    resetsAt: parseISODate(detail["resetTime"] as? String)
                ))
        }

        // Plan window. The response carries no duration for this one; observed resets
        // are 7 days out, which matches the plan's advertised billing window.
        if let usage = json["usage"] as? [String: Any], let percent = percentUsed(usage) {
            windows.append(
                Window(
                    id: "kimi.plan",
                    provider: .kimi,
                    label: "7d",
                    percent: percent,
                    resetsAt: parseISODate(usage["resetTime"] as? String)
                ))
        }

        return windows
    }

    private func percentUsed(_ detail: [String: Any]) -> Double? {
        guard let limit = number(detail["limit"]), limit > 0 else { return nil }
        if let remaining = number(detail["remaining"]) {
            return (limit - remaining) / limit * 100
        }
        if let used = number(detail["used"]) { return used / limit * 100 }
        return nil
    }

    private func secondsPerUnit(_ unit: String) -> Double {
        switch unit {
        case "TIME_UNIT_SECOND": return 1
        case "TIME_UNIT_MINUTE": return 60
        case "TIME_UNIT_HOUR": return 3600
        case "TIME_UNIT_DAY": return 86400
        default: return 0
        }
    }
}

/// Kimi returns numbers as strings.
private func number(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let string = value as? String { return Double(string) }
    return nil
}
