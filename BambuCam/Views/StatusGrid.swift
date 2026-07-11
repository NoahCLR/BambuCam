import SwiftUI
import BambuKit

/// Print status presented compactly enough to live over the camera feed.
struct StatusGrid: View {
    let status: PrinterStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(printState, systemImage: stateIcon)
                    .font(.headline)
                Spacer(minLength: 12)
                Text(progressText)
                    .font(.title3.monospacedDigit().weight(.semibold))
            }

            ProgressView(value: progressValue, total: 1)
                .progressViewStyle(.linear)
                .tint(progressTint)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    field("Nozzle", temp(status?.nozzleTemper, status?.nozzleTargetTemper))
                    field("Bed", temp(status?.bedTemper, status?.bedTargetTemper))
                    field("Layer", layerProgressText)
                }
                GridRow {
                    field("Stage", status?.mcPrintStage ?? "–")
                    field("Remaining", status?.mcRemainingTime.map { "\($0) min" } ?? "–")
                    field("State", status?.gcodeState ?? "–")
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }

    private var printState: String {
        switch status?.gcodeState {
        case "RUNNING": "Printing"
        case "PAUSE": "Paused"
        case "FINISH": "Finished"
        case let state?: state.capitalized
        case nil: "No Status"
        }
    }

    private var stateIcon: String {
        switch status?.gcodeState {
        case "RUNNING": "printer.filled.and.paper"
        case "PAUSE": "pause.circle.fill"
        case "FINISH": "checkmark.circle.fill"
        case nil: "dot.radiowaves.left.and.right"
        default: "printer"
        }
    }

    private var progressValue: Double {
        Double(status?.mcPercent ?? 0) / 100
    }

    private var progressText: String {
        status?.mcPercent.map { "\($0)%" } ?? "–"
    }

    private var layerProgressText: String {
        switch (status?.layerNum, status?.totalLayerNum) {
        case let (current?, total?) where total > 0:
            "\(current)/\(total)"
        case let (current?, _):
            "\(current)/–"
        case let (nil, total?) where total > 0:
            "–/\(total)"
        default:
            "–/–"
        }
    }

    private var progressTint: Color {
        switch status?.gcodeState {
        case "RUNNING": .green
        case "PAUSE": .orange
        case "FINISH": .blue
        default: .secondary
        }
    }

    private func temp(_ current: Double?, _ target: Double?) -> String {
        let c = current.map { String(format: "%.1f°", $0) } ?? "–"
        let t = target.map { String(format: "%.0f°", $0) } ?? "–"
        return "\(c) / \(t)"
    }
}
