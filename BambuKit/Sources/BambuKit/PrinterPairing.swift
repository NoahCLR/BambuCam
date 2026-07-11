import CryptoKit
import Foundation
import Network
import Security

public enum PrinterPairingError: Error {
    case certificateUnavailable
    /// MQTT answered but neither camera port did: the printer is reachable
    /// and the camera service itself is down (hung on P1/A1 — a reboot
    /// usually clears it — or LAN Mode Liveview disabled on X1).
    case cameraUnavailable
}

/// Certificates observed during an explicit, user-confirmed first pairing.
/// They are never written to the JSON preferences file.
public struct PrinterPairing: Sendable {
    public let mqttCertificateDER: Data
    public let cameraCertificateDER: Data
    public let cameraTransport: CameraTransport

    public var mqttFingerprint: String { Self.fingerprint(for: mqttCertificateDER) }
    public var cameraFingerprint: String { Self.fingerprint(for: cameraCertificateDER) }

    /// Probes MQTT plus both camera ports; whichever camera port answers
    /// determines the transport (real printers only open one; prefer the
    /// known-good JPEG port if somehow both do). No camera port at all fails
    /// pairing — on X1 that happens until LAN Mode Liveview is enabled.
    public static func discover(hostname: String) async throws -> PrinterPairing {
        async let mqtt = PrinterCertificateProbe.fetch(hostname: hostname, port: 8883)
        async let jpegCamera = optionalProbe(hostname: hostname, port: 6000)
        async let rtspCamera = optionalProbe(hostname: hostname, port: 322)

        let mqttCertificate = try await mqtt
        if let camera = await jpegCamera {
            return PrinterPairing(mqttCertificateDER: mqttCertificate,
                                  cameraCertificateDER: camera,
                                  cameraTransport: .jpegStream)
        }
        if let camera = await rtspCamera {
            return PrinterPairing(mqttCertificateDER: mqttCertificate,
                                  cameraCertificateDER: camera,
                                  cameraTransport: .rtsp)
        }
        throw PrinterPairingError.cameraUnavailable
    }

    private static func optionalProbe(hostname: String, port: UInt16) async -> Data? {
        try? await PrinterCertificateProbe.fetch(hostname: hostname, port: port)
    }

    public static func fingerprint(for certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

/// Retrieves a leaf certificate without sending printer credentials. The caller
/// must show its fingerprint and obtain user consent before persisting it.
private enum PrinterCertificateProbe {
    static func fetch(hostname: String, port: UInt16) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let state = ProbeState(continuation: continuation)
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, secTrust, complete in
                    let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                    let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
                    // This connection is only a credential-free certificate
                    // probe. It must never become an authenticated session.
                    complete(false)
                    guard let certificate else {
                        state.fail(PrinterPairingError.certificateUnavailable)
                        return
                    }
                    state.succeed(SecCertificateCopyData(certificate) as Data)
                },
                DispatchQueue(label: "BambuKit.certificate-probe")
            )

            let connection = NWConnection(
                host: .init(hostname),
                port: .init(rawValue: port)!,
                using: NWParameters(tls: tls)
            )
            state.setConnection(connection)
            connection.stateUpdateHandler = { stateUpdate in
                switch stateUpdate {
                case .failed, .cancelled, .ready:
                    // A ready connection would mean verification did not run;
                    // fail closed rather than allowing any application data.
                    state.fail(PrinterPairingError.certificateUnavailable)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "BambuKit.certificate-probe.connection"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                state.fail(PrinterPairingError.certificateUnavailable)
            }
        }
    }

    private final class ProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, any Error>?
        private var connection: NWConnection?

        init(continuation: CheckedContinuation<Data, any Error>) {
            self.continuation = continuation
        }

        func setConnection(_ connection: NWConnection) {
            lock.lock()
            self.connection = connection
            lock.unlock()
        }

        func succeed(_ data: Data) { complete(.success(data)) }
        func fail(_ error: any Error) { complete(.failure(error)) }

        private func complete(_ result: Result<Data, any Error>) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            let connection = self.connection
            lock.unlock()

            connection?.cancel()
            continuation.resume(with: result)
        }
    }
}
