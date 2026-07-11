import Foundation
import Network

/// Streams H.264 frames from an X1-series printer camera: RTSPS (RTSP over
/// TLS) on :322, video as TCP-interleaved RTP. All protocol logic lives in
/// `RTSPSession`; this class only moves bytes. Same contract as
/// `CameraClient`: one `frames()` call is one connection, the stream
/// finishes on any failure, and the caller decides whether to reconnect.
public final class RTSPCameraClient: Sendable {
    private let hostname: String
    private let accessCode: String
    private let certificateDER: Data
    private let port: UInt16 = 322

    public init(hostname: String, accessCode: String, certificateDER: Data) {
        self.hostname = hostname
        self.accessCode = accessCode
        self.certificateDER = certificateDER
    }

    public func frames() -> AsyncStream<CameraFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraFrame.self,
            bufferingPolicy: .bufferingNewest(16))

        let uri = "rtsps://\(hostname):\(port)/streaming/live/1"
        let box = SessionBox(session: RTSPSession(uri: uri, username: "bblp", password: accessCode))

        let tlsOptions = PinnedTLS.options(certificateDER: certificateDER,
                                           queueLabel: "BambuKit.rtsp-certificate-verification")
        let connection = NWConnection(
            host: .init(hostname),
            port: .init(rawValue: port)!,
            using: NWParameters(tls: tlsOptions)
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Self.apply(box.start(), to: connection, continuation)
                Self.receiveLoop(connection, box, continuation)
            case .failed, .cancelled:
                continuation.finish()
            default:
                break
            }
        }

        // The session's keepalive cadence is only known after SETUP, so the
        // timer re-reads it every cycle. RTSPSession ignores keepalives until
        // it is streaming.
        let keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: box.keepaliveInterval)
                guard !Task.isCancelled else { break }
                Self.apply(box.keepalive(), to: connection, continuation)
            }
        }
        // No incoming bytes for 10s means a dead handshake or a stalled
        // stream; kill the connection so the caller's retry loop takes over
        // (mirrors the 10s MQTT status watchdog).
        let watchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if box.timeSinceProgress > .seconds(10) {
                    continuation.finish()
                    connection.cancel()
                    break
                }
            }
        }

        continuation.onTermination = { _ in
            keepaliveTask.cancel()
            watchdogTask.cancel()
            for case .send(let data) in box.teardown() {
                connection.send(content: data, completion: .idempotent)
            }
            connection.cancel()
        }
        connection.start(queue: DispatchQueue(label: "BambuKit.rtsp-camera"))
        return stream
    }

    private static func apply(_ outputs: [RTSPSession.Output],
                              to connection: NWConnection,
                              _ continuation: AsyncStream<CameraFrame>.Continuation) {
        for output in outputs {
            switch output {
            case .send(let data):
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        continuation.finish()
                        connection.cancel()
                    }
                })
            case .frame(let accessUnit):
                continuation.yield(.h264(accessUnit))
            case .failure:
                continuation.finish()
                connection.cancel()
            }
        }
    }

    private static func receiveLoop(
        _ connection: NWConnection,
        _ box: SessionBox,
        _ continuation: AsyncStream<CameraFrame>.Continuation
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data {
                apply(box.receive(data), to: connection, continuation)
            }
            if isComplete || error != nil {
                continuation.finish()
                connection.cancel()
                return
            }
            receiveLoop(connection, box, continuation)
        }
    }

    /// Serializes session access: the connection queue, the keepalive timer,
    /// and the watchdog all touch it, so unlike CameraClient's ParserBox this
    /// needs a real lock.
    private final class SessionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var session: RTSPSession
        private var lastProgress = ContinuousClock.now

        init(session: RTSPSession) {
            self.session = session
        }

        func start() -> [RTSPSession.Output] {
            lock.withLock { session.start() }
        }

        func receive(_ data: Data) -> [RTSPSession.Output] {
            lock.withLock {
                lastProgress = .now
                return session.receive(data)
            }
        }

        func keepalive() -> [RTSPSession.Output] {
            lock.withLock { session.keepalive() }
        }

        func teardown() -> [RTSPSession.Output] {
            lock.withLock { session.teardown() }
        }

        var keepaliveInterval: Duration {
            lock.withLock { session.keepaliveInterval }
        }

        var timeSinceProgress: Duration {
            lock.withLock { lastProgress.duration(to: .now) }
        }
    }
}
