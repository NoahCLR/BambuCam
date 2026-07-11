import SwiftUI
import BambuKit

struct MainWindowView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var selectedSpeed: PrinterCommand.PrintSpeed = .normal
    @State private var isZoomed = false
    @State private var isFullScreen = false
    @State private var windowHandle = MainWindowHandle()

    var body: some View {
        ZStack {
            // Always full-bleed under the (transparent, floating) toolbar.
            // Layout must not depend on zoom/fullscreen — swapping view
            // structure on those transitions causes a visible black flash.
            CameraView(image: model.latestFrame,
                       placeholderText: stateText,
                       isZoomed: $isZoomed)
                .ignoresSafeArea(.container, edges: .top)

            if !isZoomed {
                // In full screen the camera ignores the top inset, so the HUD
                // must too — otherwise its top row is fenced off from the
                // letterbox band above the video.
                overlayHUD
                    .ignoresSafeArea(.container, edges: isFullScreen ? .top : [])
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isZoomed)
        .background(.black)
        .frame(minWidth: 920, minHeight: 620)
        .toolbar {
            // With the window title removed nothing occupies the flexible
            // space, so trailing items collapse against the traffic lights —
            // push them right explicitly.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) { Spacer() }
            }

            ToolbarItem(placement: .primaryAction) {
                connectionBadge
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button("Reconnect", systemImage: "arrow.clockwise") {
                    Task { await model.reconnect() }
                }
                .help("Reconnect to printer")

                Button("Open Slicer", systemImage: "cube") {
                    model.openSlicer()
                }
                .help("Open \(model.slicerName ?? "slicer")")

                Button("Settings", systemImage: "gearshape") {
                    openSettings()
                }
                .help("Open settings")
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbarVisibility(chromeHidden ? .hidden : .automatic, for: .windowToolbar)
        .background(MainWindowResolver(handle: windowHandle))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === windowHandle.window else { return }
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window === windowHandle.window else { return }
            isFullScreen = false
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .bambuGlassPanel(cornerRadius: 18)
                    .padding(.bottom, 108)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .onAppear {
            model.cameraViewerAppeared()
            model.openMainWindow = {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            model.openSettings = {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            model.cameraViewerDisappeared()
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder private var overlayHUD: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                hudLayout
            }
        } else {
            hudLayout
        }
    }

    private var hudLayout: some View {
        VStack(spacing: 0) {
            // Full screen hides the toolbar, so the HUD recreates its
            // top-right cluster there — same position, same options.
            if isFullScreen {
                HStack(spacing: 8) {
                    Spacer()

                    connectionBadge

                    HStack(spacing: 2) {
                        cornerButton("arrow.clockwise", help: "Reconnect to printer") {
                            Task { await model.reconnect() }
                        }
                        cornerButton("cube", help: "Open \(model.slicerName ?? "slicer")") {
                            model.openSlicer()
                        }
                        cornerButton("gearshape", help: "Open settings") {
                            openSettings()
                        }
                    }
                    .padding(3)
                    .bambuGlassPanel(cornerRadius: 19, interactive: true)
                }
            }

            Spacer(minLength: 0)

            // The corner cluster shares the bottom band with the deck. A
            // hidden twin keeps the status pill centered.
            HStack(alignment: .bottom, spacing: 10) {
                cornerControls.hidden()
                controlDeck
                cornerControls
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Window-mode controls pinned to the bottom-right corner of the feed.
    private var cornerControls: some View {
        HStack(spacing: 2) {
            if PiPController.isSupported {
                cornerButton(model.isPiPPresented ? "pip.exit" : "pip.enter",
                             help: model.isPiPPresented ? "Close Picture in Picture" : "Open Picture in Picture") {
                    model.togglePiP()
                }
            }

            cornerButton(isFullScreen ? "arrow.down.right.and.arrow.up.left"
                                      : "arrow.up.left.and.arrow.down.right",
                         help: isFullScreen ? "Exit Full Screen" : "Enter Full Screen") {
                windowHandle.toggleFullScreen()
            }
        }
        .padding(3)
        .bambuGlassPanel(cornerRadius: 19, interactive: true)
    }

    private func cornerButton(_ systemImage: String,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var controlDeck: some View {
        PrinterStatusPill(
            status: model.status,
            maxWidth: 760,
            lightOn: model.lightOn,
            lightToggle: {
                Task { await model.send(.light(on: !(model.lightOn ?? false))) }
            },
            showsPrintControls: model.canSendPrintCommands,
            isPaused: isPaused,
            selectedSpeed: $selectedSpeed,
            pauseResume: { Task { await model.send(isPaused ? .resume : .pause) } },
            stop: { Task { await model.send(.stop) } },
            speedChanged: { speed in Task { await model.send(.speed(speed)) } }
        )
        .frame(maxWidth: .infinity)
    }

    /// Zoom and full screen hide all window chrome (toolbar, HUD, extension).
    private var chromeHidden: Bool {
        isZoomed || isFullScreen
    }

    private var isPaused: Bool {
        model.status?.gcodeState?.uppercased() == "PAUSE"
    }

    private var connectionBadge: some View {
        ConnectionPill(text: stateBadgeText, color: badgeColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .bambuGlassPanel(cornerRadius: 18)
    }

    private var stateText: String {
        switch model.connectionState {
        case .connected: "Waiting for camera…"
        case .connecting: "Connecting…"
        case .degraded: "Reconnecting…"
        case .disconnected: "Disconnected"
        }
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
}

/// Keeps AppKit-only window behavior scoped to the SwiftUI scene instance that
/// owns this view. In particular, this must not use `NSApp.keyWindow`: a menu
/// or a newly recreated scene can make a different window key.
@MainActor
private final class MainWindowHandle {
    private(set) weak var window: NSWindow?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window

        // Do not let AppKit pick the first button in the key-view loop when a
        // fresh scene is shown. The deferred clear catches SwiftUI's initial
        // focus assignment, which happens after the hosting view is attached.
        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(nil)
        }
    }

    func detach(_ window: NSWindow?) {
        guard self.window === window else { return }
        self.window = nil
    }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
}

/// A zero-size bridge that reports the actual host window for this scene.
private struct MainWindowResolver: NSViewRepresentable {
    let handle: MainWindowHandle

    func makeNSView(context: Context) -> ResolverView {
        ResolverView(handle: handle)
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.resolveWindow()
    }

    static func dismantleNSView(_ nsView: ResolverView, coordinator: ()) {
        nsView.detachWindow()
    }

    @MainActor
    final class ResolverView: NSView {
        private let handle: MainWindowHandle
        private weak var resolvedWindow: NSWindow?

        init(handle: MainWindowHandle) {
            self.handle = handle
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveWindow()
        }

        func resolveWindow() {
            guard let window, resolvedWindow !== window else { return }
            resolvedWindow = window
            handle.attach(window)
        }

        func detachWindow() {
            handle.detach(resolvedWindow)
            resolvedWindow = nil
        }
    }
}

struct ConnectionPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

struct PrinterStatusPill: View {
    let status: PrinterStatus?
    var maxWidth: CGFloat
    var lightOn: Bool?
    /// The light remains anchored in the status row in every mode.
    var lightToggle: (() -> Void)?
    var showsPrintControls: Bool
    var isPaused: Bool
    @Binding var selectedSpeed: PrinterCommand.PrintSpeed
    var pauseResume: () -> Void
    var stop: () -> Void
    var speedChanged: (PrinterCommand.PrintSpeed) -> Void

    private let statusRailWidth: CGFloat = 88
    private let actionRailWidth: CGFloat = 72
    private let statusRowHeight: CGFloat = 24
    private let statusRowSpacing: CGFloat = 3

    var body: some View {
        VStack(spacing: 0) {
            statusContent
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            if showsPrintControls {
                Divider()
                    .padding(.horizontal, 16)

                PrinterControlRow(
                    isPaused: isPaused,
                    selectedSpeed: $selectedSpeed,
                    pauseResume: pauseResume,
                    stop: stop,
                    speedChanged: speedChanged
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: maxWidth)
        .bambuGlassPanel(cornerRadius: 28, interactive: true)
    }

    private var statusContent: some View {
        HStack(spacing: 16) {
            statusIdentity
                .frame(width: statusRailWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: statusRowSpacing) {
                HStack(spacing: 10) {
                    heroProgressBar
                    progressPercentage
                }
                .frame(height: statusRowHeight)

                HStack(spacing: 12) {
                    inlineMetric("Nozzle", temp(status?.nozzleTemper, status?.nozzleTargetTemper))
                    inlineMetric("Bed", temp(status?.bedTemper, status?.bedTargetTemper))
                    Spacer(minLength: 12)
                    timeSummary
                }
            }
            .frame(maxWidth: .infinity)

            trailingStatusRail
                .frame(width: actionRailWidth)
        }
    }

    @ViewBuilder private var trailingStatusRail: some View {
        if let lightToggle {
            HStack(spacing: 0) {
                Divider()
                    .frame(height: 42)
                lightButton(lightToggle)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .offset(x: 8)
            }
        } else {
            Color.clear
        }
    }

    private func lightButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: lightOn == true ? "lightbulb.fill" : "lightbulb")
                .font(.callout.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(lightOn == true ? Color.primary.opacity(0.10) : .clear,
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(lightOn == true ? "Turn chamber light off" : "Turn chamber light on")
    }

    private var statusLabel: some View {
        Label(printState, systemImage: stateIcon)
            .font(.callout.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var statusIdentity: some View {
        VStack(alignment: .leading, spacing: statusRowSpacing) {
            statusLabel
                .frame(height: statusRowHeight, alignment: .leading)
            inlineMetric("Layer", layerProgressText)
        }
    }

    private var progressPercentage: some View {
        Text(progressText)
            .font(.title3.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
            .frame(minWidth: 42, alignment: .trailing)
    }

    private var heroProgressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(progressTint)
                    .frame(width: proxy.size.width * clampedProgressValue)
            }
        }
        .frame(minWidth: 180, maxWidth: .infinity)
        .frame(height: 10)
        .animation(.easeOut(duration: 0.25), value: clampedProgressValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Print progress")
        .accessibilityValue(progressText)
    }

    @ViewBuilder private var timeSummary: some View {
        if let timeEstimate {
            HStack(spacing: 7) {
                Text(timeEstimate.remainingText)
                if isPrinting {
                    Text("·")
                        .accessibilityHidden(true)
                    Text(timeEstimate.doneAtText())
                }
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    private func inlineMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .font(.caption.monospacedDigit())
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

    private var clampedProgressValue: Double {
        min(max(progressValue, 0), 1)
    }

    private var progressText: String {
        status?.mcPercent.map { "\($0)%" } ?? "-"
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

    private var timeEstimate: PrintTimeEstimate? {
        PrintTimeEstimate(remainingMinutes: status?.mcRemainingTime)
    }

    private var isPrinting: Bool {
        status?.gcodeState?.uppercased() == "RUNNING"
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
        let c = current.map { String(format: "%.1f°", $0) } ?? "-"
        let t = target.map { String(format: "%.0f°", $0) } ?? "-"
        return "\(c) / \(t)"
    }
}

struct PrinterControlRow: View {
    let isPaused: Bool
    @Binding var selectedSpeed: PrinterCommand.PrintSpeed
    let pauseResume: () -> Void
    let stop: () -> Void
    let speedChanged: (PrinterCommand.PrintSpeed) -> Void
    @State private var isConfirmingStop = false

    var body: some View {
        HStack(spacing: 8) {
            Button(isPaused ? "Resume" : "Pause",
                   systemImage: isPaused ? "play.fill" : "pause.fill",
                   action: pauseResume)

            speedMenu

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 2)

            Button("Stop", systemImage: "stop.fill", role: .destructive) {
                isConfirmingStop = true
            }
            .tint(.red)
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
        .confirmationDialog("Stop this print?",
                            isPresented: $isConfirmingStop,
                            titleVisibility: .visible) {
            Button("Stop Print", role: .destructive, action: stop)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current print will be cancelled on the printer.")
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PrinterCommand.PrintSpeed.allCases) { speed in
                Button {
                    selectedSpeed = speed
                    speedChanged(speed)
                } label: {
                    if speed == selectedSpeed {
                        Label(speed.displayName, systemImage: "checkmark")
                    } else {
                        Text(speed.displayName)
                    }
                }
            }
        } label: {
            // The button menu style flattens the label to icon + title
            // with a near-zero gap, discarding any layout spacing — the
            // leading en-space is the gap.
            Label("\u{2002}" + selectedSpeed.displayName, systemImage: "speedometer")
        }
        .menuStyle(.button)
        .buttonBorderShape(.capsule)
        .fixedSize()
    }
}

struct BambuGlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var interactive = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
        }
    }
}

extension View {
    func bambuGlassPanel(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(BambuGlassPanelModifier(cornerRadius: cornerRadius, interactive: interactive))
    }
}
