import Foundation

/// Snapshot of printer state, merged from cumulative partial MQTT reports.
/// Field names mirror the printer's report keys (snake_case in JSON).
public struct PrinterStatus: Sendable, Equatable {
    public var nozzleTemper: Double?
    public var nozzleTargetTemper: Double?
    public var bedTemper: Double?
    public var bedTargetTemper: Double?
    public var layerNum: Int?
    public var totalLayerNum: Int?
    public var mcPercent: Int?
    public var mcPrintStage: String?
    public var mcRemainingTime: Int?
    public var gcodeState: String?
    public var lightOn: Bool?

    public init() {}
}

/// Merges partial `{"print": {...}}` MQTT messages into a running snapshot,
/// like the legacy WatchClient's cumulative dict.
public struct StatusAccumulator {
    private var values: [String: Any] = [:]

    public init() {}

    public mutating func ingest(_ messageData: Data) -> PrinterStatus? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any]
        else { return nil }

        if let report = obj["print"] as? [String: Any] {
            values.merge(report) { _, new in new }
            return snapshot()
        }

        if let system = obj["system"] as? [String: Any],
           (system["command"] as? String) == "ledctrl",
           let node = system["led_node"] as? String,
           let mode = system["led_mode"] as? String {
            values["lights_report"] = [["node": node, "mode": mode]]
            return snapshot()
        }

        return nil
    }

    private func snapshot() -> PrinterStatus {
        var status = PrinterStatus()
        status.nozzleTemper = double("nozzle_temper")
        status.nozzleTargetTemper = double("nozzle_target_temper")
        status.bedTemper = double("bed_temper")
        status.bedTargetTemper = double("bed_target_temper")
        status.layerNum = int("layer_num")
        status.totalLayerNum = int("total_layer_num")
        status.mcPercent = int("mc_percent")
        status.mcPrintStage = values["mc_print_stage"].flatMap { "\($0)" }
        status.mcRemainingTime = int("mc_remaining_time")
        status.gcodeState = values["gcode_state"] as? String
        status.lightOn = lightOn()
        return status
    }

    private func lightOn() -> Bool? {
        guard let reports = values["lights_report"] as? [[String: Any]] else { return nil }
        let knownNodes = ["chamber_light", "camera_light"]
        let report = reports.first { report in
            guard let node = report["node"] as? String else { return false }
            return knownNodes.contains(node)
        } ?? reports.first

        guard let mode = report?["mode"] as? String else { return nil }
        switch mode.lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    private func double(_ key: String) -> Double? {
        (values[key] as? NSNumber)?.doubleValue
    }
    private func int(_ key: String) -> Int? {
        (values[key] as? NSNumber)?.intValue
    }
}
