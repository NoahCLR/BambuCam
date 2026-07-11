import Foundation

/// Supervises one printer: MQTT status link (always on) + camera stream
/// (only while a view is showing it), 10s status watchdog, reconnect with
/// exponential backoff.
public actor PrinterConnection {
    public enum ConnectionState: Sendable, Equatable {
        case connecting, connected, degraded, disconnected
    }

    public nonisolated let frames: AsyncStream<CameraFrame>
    public nonisolated let statusUpdates: AsyncStream<PrinterStatus>
    public nonisolated let stateUpdates: AsyncStream<ConnectionState>

    private let frameContinuation: AsyncStream<CameraFrame>.Continuation
    private let statusContinuation: AsyncStream<PrinterStatus>.Continuation
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    private let hostname: String
    private let accessCode: String
    private let serial: String
    private let mqttCertificateDER: Data
    private let cameraCertificateDER: Data
    private let cameraTransport: CameraTransport

    private var printerClient: PrinterClient?
    private var supervisorTask: Task<Void, Never>?
    private var cameraTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var cameraActive = false
    private var lastStatus: PrinterStatus?
    private var lastStatusChange = ContinuousClock.now
    private var state: ConnectionState = .disconnected {
        didSet { if state != oldValue { stateContinuation.yield(state) } }
    }

    public init(hostname: String, accessCode: String, serial: String,
                mqttCertificateDER: Data, cameraCertificateDER: Data,
                cameraTransport: CameraTransport = .jpegStream) {
        self.hostname = hostname
        self.accessCode = accessCode
        self.serial = serial
        self.mqttCertificateDER = mqttCertificateDER
        self.cameraCertificateDER = cameraCertificateDER
        self.cameraTransport = cameraTransport
        // 16, not 2: dropping H.264 access units corrupts decoding until the
        // next IDR, so give a stalled consumer more slack than JPEG needed.
        (frames, frameContinuation) = AsyncStream.makeStream(of: CameraFrame.self, bufferingPolicy: .bufferingNewest(16))
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: PrinterStatus.self, bufferingPolicy: .bufferingNewest(1))
        (stateUpdates, stateContinuation) = AsyncStream.makeStream(of: ConnectionState.self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        guard supervisorTask == nil else { return }
        supervisorTask = Task { await supervise() }
    }

    public func stop() {
        supervisorTask?.cancel(); supervisorTask = nil
        cameraTask?.cancel(); cameraTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        let client = printerClient
        printerClient = nil
        state = .disconnected
        Task { await client?.disconnect() }
    }

    public func reconnect() async {
        // Tear down; supervisor loop rebuilds on next iteration.
        let client = printerClient
        printerClient = nil
        state = .degraded
        await client?.disconnect()
    }

    public func send(_ command: PrinterCommand) async {
        if state != .connected {
            await reconnect()
            // Give the supervisor a moment to rebuild the link.
            for _ in 0..<50 where state != .connected {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        try? await printerClient?.send(command)
    }

    public func setCameraActive(_ active: Bool) {
        cameraActive = active
        if !active {
            cameraTask?.cancel()
            cameraTask = nil
        } else if state == .connected, cameraTask == nil {
            startCamera()
        }
    }

    // MARK: - Supervision

    private func supervise() async {
        var backoff = ReconnectBackoff()
        while !Task.isCancelled {
            state = .connecting
            let client = PrinterClient(hostname: hostname, accessCode: accessCode, serial: serial,
                                       certificateDER: mqttCertificateDER)
            do {
                try await client.connect()
                printerClient = client
                state = .connected
                backoff.reset()
                lastStatus = nil
                lastStatusChange = ContinuousClock.now
                startWatchdog()
                if cameraActive { startCamera() }

                for await status in await client.statusUpdates() {
                    if status != lastStatus {
                        lastStatus = status
                        lastStatusChange = ContinuousClock.now
                    }
                    statusContinuation.yield(status)
                }
                // Status stream ended: link is gone.
            } catch {
                // connect failed; fall through to backoff
            }
            watchdogTask?.cancel(); watchdogTask = nil
            cameraTask?.cancel(); cameraTask = nil
            await client.disconnect()
            if printerClient === client { printerClient = nil }
            guard !Task.isCancelled else { break }
            state = .degraded
            try? await Task.sleep(for: backoff.nextDelay())
        }
        state = .disconnected
    }

    private func startCamera() {
        cameraTask?.cancel()
        let hostname = hostname
        let accessCode = accessCode
        let certificateDER = cameraCertificateDER
        let transport = cameraTransport
        let frameContinuation = frameContinuation
        cameraTask = Task {
            while !Task.isCancelled {
                switch transport {
                case .jpegStream:
                    let camera = CameraClient(hostname: hostname, accessCode: accessCode,
                                              certificateDER: certificateDER)
                    for await frame in camera.frames() {
                        frameContinuation.yield(.jpeg(frame))
                        if Task.isCancelled { return }
                    }
                case .rtsp:
                    let camera = RTSPCameraClient(hostname: hostname, accessCode: accessCode,
                                                  certificateDER: certificateDER)
                    for await frame in camera.frames() {
                        frameContinuation.yield(frame)
                        if Task.isCancelled { return }
                    }
                }
                // Camera stream dropped; retry after a beat while still active.
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Legacy check_for_inactivity: no status change for 10s => rebuild link.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                if state == .connected,
                   ContinuousClock.now - lastStatusChange > .seconds(10) {
                    await reconnect()
                }
            }
        }
    }
}
