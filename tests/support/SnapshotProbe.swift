import Foundation

@main
struct SnapshotProbe {
    static func main() throws {
        let data = try Data(contentsOf: URL(filePath: CommandLine.arguments[1]))
        let snapshot = try JSONDecoder().decode(PanelSnapshot.self, from: data)
        let spend = snapshot.spend[.claude]!
        let model = snapshot.models[.claudeCode]!["claude-opus-5-5"]!
        let roundTrip = try JSONDecoder().decode(PanelSnapshot.self, from: JSONEncoder().encode(snapshot))
        let result: [String: Any] = [
            "total": spend.counts.total, "one_hour": spend.counts.cacheWrite1h,
            "cost": spend.wouldCost, "incomplete": spend.isIncomplete,
            "model_cost": model.wouldCost,
            "round_trip_cost": roundTrip.spend[.claude]!.wouldCost
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
