import SwiftUI
import BambuKit

struct MenuBarView: View {
    @Bindable var model: AppModel
    var dismissPopover: () -> Void = {}
    @State private var selectedSpeed: PrinterCommand.PrintSpeed = .normal

    private let popoverWidth: CGFloat = 368
    private let contentWidth: CGFloat = 344

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    menuContent
                }
            } else {
                menuContent
            }
        }
        .onAppear {
            model.cameraViewerAppeared()
        }
        .onDisappear { model.cameraViewerDisappeared() }
    }

    private var menuContent: some View {
        VStack(spacing: 8) {
            connectionHeader

            cameraPreview

            controlSheet
        }
        .padding(12)
        .frame(width: popoverWidth)
    }

    private var connectionHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.activePrinter?.name ?? "BambuCam")
                    .font(.headline)
                    .lineLimit(1)

                ConnectionPill(text: stateBadgeText, color: badgeColor)
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                headerButton("Settings", systemImage: "gearshape") {
                    dismissPopover()
                    model.openSettings?()
                }

                Divider()
                    .frame(height: 20)

                headerButton("Quit BambuCam", systemImage: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(3)
            .bambuGlassPanel(cornerRadius: 13, interactive: true)
        }
        .frame(width: contentWidth)
    }

    private var controlSheet: some View {
        VStack(spacing: 10) {
            compactStatusRow

            if shouldShowProgress {
                progressRow
            }

            if model.canSendPrintCommands && shouldShowPrintControls {
                developerControlsRow
            }

            if shouldShowProgress || (model.canSendPrintCommands && shouldShowPrintControls) {
                Divider()
            }

            utilityRow
        }
        .frame(width: contentWidth)
    }

    private var compactStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(statusTitle, systemImage: statusIcon)
                .font(.callout.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)

            Spacer(minLength: 8)

            if hasTemperatures {
                HStack(spacing: 10) {
                    if let nozzle = model.status?.nozzleTemper {
                        compactMetric("Nozzle", shortTemp(nozzle))
                    }
                    if let bed = model.status?.bedTemper {
                        compactMetric("Bed", shortTemp(bed))
                    }
                }
            } else {
                Text("Waiting")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var progressRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                ProgressView(value: progressValue, total: 1)
                    .progressViewStyle(.linear)
                    .tint(progressTint)

                Text(progressText)
                    .fixedSize()
            }

            HStack(spacing: 8) {
                if let layerProgressText {
                    (Text("Layer ").foregroundStyle(.secondary) + Text(layerProgressText))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let timeEstimate = PrintTimeEstimate(remainingMinutes: model.status?.mcRemainingTime) {
                    Text(timeEstimate.remainingText)
                        .frame(maxWidth: .infinity, alignment: .center)
                    if isRunning {
                        Text(timeEstimate.doneAtText())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Text("")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(.caption.monospacedDigit().weight(.medium))
    }

    private var developerControlsRow: some View {
        HStack(spacing: 8) {
            if isPaused {
                commandButton("Resume", systemImage: "play.fill") {
                    Task { await model.send(.resume) }
                }
            } else {
                commandButton("Pause", systemImage: "pause.fill") {
                    Task { await model.send(.pause) }
                }
            }

            Menu {
                ForEach(PrinterCommand.PrintSpeed.allCases) { speed in
                    Button {
                        selectedSpeed = speed
                        Task { await model.send(.speed(speed)) }
                    } label: {
                        if speed == selectedSpeed {
                            Label(speed.displayName, systemImage: "checkmark")
                        } else {
                            Text(speed.displayName)
                        }
                    }
                }
            } label: {
                Label(selectedSpeed.displayName, systemImage: "speedometer")
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)

            commandButton("Stop", systemImage: "stop.fill", role: .destructive) {
                Task { await model.send(.stop) }
            }
            .tint(.red)
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private var utilityRow: some View {
        HStack(spacing: 8) {
            utilityButton("Open Window", systemImage: "macwindow") {
                dismissPopover()
                model.openMainWindow?()
            }

            utilityButton("Slicer", systemImage: "cube") {
                model.openSlicer()
                dismissPopover()
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }

    private func commandButton(_ title: String,
                               systemImage: String,
                               role: ButtonRole? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private func utilityButton(_ title: String,
                               systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private var cameraPreview: some View {
        ZStack {
            Button {
                dismissPopover()
                model.openMainWindow?()
            } label: {
                ZStack {
                    Color.black

                    if let frame = model.latestFrame {
                        Image(nsImage: frame)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(stateText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open camera in window")
            .accessibilityLabel("Open camera in window")

            VStack {
                HStack {
                    Spacer()
                    cameraLightButton
                }
                Spacer()
                HStack {
                    Spacer()
                    cameraPiPButton
                }
            }
            .padding(10)
        }
        .frame(width: contentWidth, height: contentWidth * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var cameraLightButton: some View {
        Button {
            Task { await model.send(.light(on: !(model.lightOn ?? false))) }
        } label: {
            Image(systemName: lightIcon)
                .font(.callout.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(model.lightOn == true ? Color.primary.opacity(0.10) : .clear,
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .bambuGlassPanel(cornerRadius: 17, interactive: true)
        .help(lightHelp)
        .accessibilityLabel(lightHelp)
    }

    @ViewBuilder private var cameraPiPButton: some View {
        if PiPController.isSupported {
            let help = model.isPiPPresented ? "Close Picture in Picture" : "Open Picture in Picture"
            Button {
                model.togglePiP()
                dismissPopover()
            } label: {
                Image(systemName: model.isPiPPresented ? "pip.exit" : "pip.enter")
                    .font(.callout.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .bambuGlassPanel(cornerRadius: 17, interactive: true)
            .help(help)
            .accessibilityLabel(help)
        }
    }

    private func headerButton(_ help: String,
                              systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    private var stateBadgeText: String {
        switch model.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .degraded: "Reconnecting"
        case .disconnected: "Offline"
        }
    }

    private var badgeColor: Color {
        switch model.connectionState {
        case .connected: .green
        case .connecting, .degraded: .orange
        case .disconnected: .red
        }
    }

    private var normalizedGcodeState: String? {
        model.status?.gcodeState?.uppercased()
    }

    private var isRunning: Bool {
        normalizedGcodeState == "RUNNING"
    }

    private var isPaused: Bool {
        normalizedGcodeState == "PAUSE"
    }

    private var shouldShowPrintControls: Bool {
        isRunning || isPaused
    }

    private var shouldShowProgress: Bool {
        shouldShowPrintControls && model.status?.mcPercent != nil
    }

    private var hasTemperatures: Bool {
        model.status?.nozzleTemper != nil || model.status?.bedTemper != nil
    }

    private var statusTitle: String {
        switch normalizedGcodeState {
        case "RUNNING": "Printing"
        case "PAUSE": "Paused"
        case "FINISH": "Finished"
        case let state?: state.capitalized
        case nil: "No Status"
        }
    }

    private var statusIcon: String {
        switch normalizedGcodeState {
        case "RUNNING": "printer.filled.and.paper"
        case "PAUSE": "pause.circle.fill"
        case "FINISH": "checkmark.circle.fill"
        case nil: "dot.radiowaves.left.and.right"
        default: "printer"
        }
    }

    private var progressValue: Double {
        Double(model.status?.mcPercent ?? 0) / 100
    }

    private var progressText: String {
        model.status?.mcPercent.map { "\($0)%" } ?? "-"
    }

    private var layerProgressText: String? {
        guard let current = model.status?.layerNum else { return nil }
        if let total = model.status?.totalLayerNum, total > 0 {
            return "\(current) / \(total)"
        }
        return "\(current) / –"
    }

    private var progressTint: Color {
        switch normalizedGcodeState {
        case "RUNNING": .green
        case "PAUSE": .orange
        case "FINISH": .blue
        default: .secondary
        }
    }

    private func shortTemp(_ value: Double) -> String {
        String(format: "%.1f°", value)
    }

    private var lightIcon: String {
        model.lightOn == true ? "lightbulb.fill" : "lightbulb"
    }

    private var lightHelp: String {
        model.lightOn == true ? "Turn chamber light off" : "Turn chamber light on"
    }

    private var stateText: String {
        switch model.connectionState {
        case .connected: "Waiting for camera…"
        case .connecting: "Connecting…"
        case .degraded: "Reconnecting…"
        case .disconnected: "Disconnected"
        }
    }
}
