import SwiftUI
import Observation
import BambuKit

@Observable @MainActor
final class AppModel {
    var latestFrame: NSImage?
    var status: PrinterStatus?
    var lightOn: Bool?
    var connectionState: PrinterConnection.ConnectionState = .disconnected
    var toast: String?
    /// Whether the system Picture in Picture window is on screen.
    private(set) var isPiPPresented = false
    /// Opens the main window; captured from a view's openWindow environment
    /// so the PiP "return to app" button works with no windows open.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Opens the SwiftUI Settings scene from AppKit-owned status item actions.
    @ObservationIgnored var openSettings: (() -> Void)?

    var config: AppConfig {
        didSet {
            try? configStore.save(config)
            if Self.connectionKey(for: config.printers.first) != Self.connectionKey(for: oldValue.printers.first) {
                rebuildConnection()
            }
        }
    }

    var activePrinter: PrinterConfig? { config.printers.first }

    /// Pause/resume/stop/speed are rejected by authorization-control firmware
    /// unless the printer is in LAN Developer Mode; the UI disables them.
    var canSendPrintCommands: Bool { activePrinter?.developerMode ?? false }

    private let configStore = ConfigStore()
    private let secretStore = PrinterSecretStore()
    private let notifications = NotificationManager()
    @ObservationIgnored private let h264Decoder = H264FrameDecoder()
    private var connection: PrinterConnection?
    private var detector = StatusTransitionDetector()
    private var streamTasks: [Task<Void, Never>] = []
    private var cameraViewers = 0
    private var degradedSince: Date?
    private var connectionLostNotified = false
    private var started = false
    private var toastGeneration = 0

    init() {
        config = configStore.load()
        Task { @MainActor in self.startIfNeeded() }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        start()
    }

    func send(_ command: PrinterCommand) async {
        guard let connection else { return }
        if case .light(let on) = command {
            lightOn = on
        }
        await connection.send(command)
        showToast(toastText(for: command))
    }

    func showToast(_ text: String) {
        toast = text
        toastGeneration += 1
        let gen = toastGeneration
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastGeneration == gen { toast = nil }
        }
    }

    func reconnect() async {
        await connection?.reconnect()
    }

    func accessCode(for printer: PrinterConfig) -> String? {
        try? secretStore.accessCode(for: printer.id)
    }

    /// Persists the access code and the explicitly user-approved TLS pins in
    /// the Keychain before saving non-secret printer preferences to disk.
    func savePairedPrinter(_ printer: PrinterConfig, accessCode: String,
                           pairing: PrinterPairing) throws {
        guard PrinterHostValidator.isAllowed(printer.hostname) else {
            throw PrinterConfigurationError.hostMustBePrivateIPv4
        }
        var printer = printer
        printer.cameraTransport = pairing.cameraTransport
        try secretStore.saveAccessCode(accessCode, for: printer.id)
        try secretStore.saveCertificate(pairing.mqttCertificateDER, for: printer.id, service: .mqtt)
        try secretStore.saveCertificate(pairing.cameraCertificateDER, for: printer.id, service: .camera)

        let shouldRebuild = Self.connectionKey(for: printer) == Self.connectionKey(for: activePrinter)
        config.printers = [printer] // single-printer UI for now
        if shouldRebuild { rebuildConnection() }
    }

    func togglePiP() {
        pip.toggle()
    }

    /// Display name of the slicer picked in Settings, nil when unset.
    var slicerName: String? {
        guard let path = config.slicerPath else { return nil }
        return FileManager.default.displayName(atPath: path)
    }

    /// Launches the configured slicer, or brings it to the front if it is
    /// already running (openApplication activates a running instance).
    func openSlicer() {
        guard let path = config.slicerPath else {
            showToast("Choose a slicer app in Settings")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            showToast("Slicer not found — pick it again in Settings")
            return
        }
        let name = slicerName ?? "slicer"
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) { [weak self] _, error in
            guard error != nil else { return }
            Task { @MainActor in self?.showToast("Couldn't open \(name)") }
        }
    }

    func cameraViewerAppeared() {
        cameraViewers += 1
        updateCameraActivity()
    }

    func cameraViewerDisappeared() {
        cameraViewers = max(0, cameraViewers - 1)
        updateCameraActivity()
    }

    // MARK: - Private

    /// PiP counts as a camera viewer so the feed survives every other scene
    /// closing; the restore button reopens the main window.
    @ObservationIgnored private lazy var pip: PiPController = {
        let pip = PiPController()
        pip.onPresentedChanged = { [weak self] presented in
            guard let self else { return }
            self.isPiPPresented = presented
            presented ? self.cameraViewerAppeared() : self.cameraViewerDisappeared()
        }
        pip.onRestoreRequested = { [weak self] in
            self?.openMainWindow?()
        }
        pip.onError = { [weak self] in
            self?.toast = "Picture in Picture unavailable"
        }
        return pip
    }()

    private func start() {
        notifications.requestPermission()
        rebuildConnection()
    }

    private static func connectionKey(for printer: PrinterConfig?) -> [String]? {
        guard let printer else { return nil }
        return [printer.hostname, printer.serial, printer.cameraTransport.rawValue]
    }

    private func updateCameraActivity() {
        let active = cameraViewers > 0
        let connection = connection
        Task { await connection?.setCameraActive(active) }
    }

    private func rebuildConnection() {
        degradedSince = nil
        connectionLostNotified = false
        streamTasks.forEach { $0.cancel() }
        streamTasks = []
        if let old = connection { Task { await old.stop() } }
        connection = nil
        detector = StatusTransitionDetector()
        status = nil
        lightOn = nil

        guard let printer = activePrinter else { return }
        guard PrinterHostValidator.isAllowed(printer.hostname) else {
            showToast("Use your printer's private IPv4 address")
            return
        }
        guard let accessCode = try? secretStore.accessCode(for: printer.id),
              !accessCode.isEmpty,
              let mqttCertificateDER = try? secretStore.certificate(for: printer.id, service: .mqtt),
              let cameraCertificateDER = try? secretStore.certificate(for: printer.id, service: .camera)
        else {
            showToast("Pair this printer in Settings before connecting")
            return
        }
        let conn = PrinterConnection(hostname: printer.hostname,
                                     accessCode: accessCode,
                                     serial: printer.serial,
                                     mqttCertificateDER: mqttCertificateDER,
                                     cameraCertificateDER: cameraCertificateDER,
                                     cameraTransport: printer.cameraTransport)
        connection = conn

        streamTasks.append(Task { [weak self] in
            for await frame in conn.frames {
                guard let self else { return }
                switch frame {
                case .jpeg(let data):
                    self.latestFrame = NSImage(data: data)
                case .h264(let accessUnit):
                    // nil while waiting for an IDR; keep the previous image.
                    if let image = self.h264Decoder.image(for: accessUnit) {
                        self.latestFrame = image
                    }
                }
                self.pip.ingest(frame)
            }
        })
        streamTasks.append(Task { [weak self] in
            for await status in conn.statusUpdates {
                self?.handle(status: status)
            }
        })
        streamTasks.append(Task { [weak self] in
            for await state in conn.stateUpdates {
                self?.handle(state: state)
            }
        })
        Task { await conn.start() }
        updateCameraActivity()
    }

    private func handle(status: PrinterStatus) {
        self.status = status
        if let reported = status.lightOn {
            lightOn = reported
        }
        for event in detector.events(for: status) {
            notifications.post(event: event, settings: config.notifications)
        }
    }

    /// Connection-lost notification only after 60s continuously degraded (debounce).
    private func handle(state: PrinterConnection.ConnectionState) {
        connectionState = state
        switch state {
        case .connected:
            degradedSince = nil
            connectionLostNotified = false
        case .degraded, .connecting:
            if degradedSince == nil {
                degradedSince = Date()
                checkConnectionLost()
            }
        case .disconnected:
            break
        }
    }

    private func checkConnectionLost() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(61))
            guard let self,
                  self.config.notifications.connectionLost,
                  !self.connectionLostNotified,
                  let since = self.degradedSince,
                  Date().timeIntervalSince(since) >= 60
            else { return }
            self.connectionLostNotified = true
            self.notifications.postConnectionLost()
        }
    }

    private func toastText(for command: PrinterCommand) -> String {
        switch command {
        case .pause: "Pause sent"
        case .resume: "Resume sent"
        case .stop: "Stop sent"
        case .light(let on): on ? "Light on" : "Light off"
        case .speed(let s): "Speed: \(s.displayName)"
        }
    }
}

enum PrinterConfigurationError: LocalizedError {
    case hostMustBePrivateIPv4

    var errorDescription: String? {
        switch self {
        case .hostMustBePrivateIPv4:
            "Use a private IPv4 address for the printer."
        }
    }
}
