import Foundation
import Network
import Security

/// Streams JPEG frames from the printer camera: TLS socket on :6000,
/// one 80-byte auth packet, then a raw JPEG byte stream.
public final class CameraClient: Sendable {
    private let hostname: String
    private let accessCode: String
    private let certificateDER: Data
    private let port: UInt16 = 6000

    public init(hostname: String, accessCode: String, certificateDER: Data) {
        self.hostname = hostname
        self.accessCode = accessCode
        self.certificateDER = certificateDER
    }

    /// Python reference: struct.pack("IIL", 0x40, 0x3000, 0x0) + user/code padded to 32.
    static func makeAuthPacket(accessCode: String) -> Data {
        var d = Data()
        for value in [UInt32(0x40), UInt32(0x3000)] {
            withUnsafeBytes(of: value.littleEndian) { d.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: UInt64(0).littleEndian) { d.append(contentsOf: $0) }
        d.append(("bblp".data(using: .ascii) ?? Data()).padded(to: 32))
        d.append((accessCode.data(using: .ascii) ?? Data()).padded(to: 32))
        return d
    }

    /// Connects and yields complete JPEG frames. Stream finishes on any
    /// connection failure; caller decides whether to reconnect.
    public func frames() -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self,
            bufferingPolicy: .bufferingNewest(2))

        let tlsOptions = PinnedTLS.options(certificateDER: certificateDER,
                                           queueLabel: "BambuKit.camera-certificate-verification")
        let params = NWParameters(tls: tlsOptions)
        let connection = NWConnection(
            host: .init(hostname),
            port: .init(rawValue: port)!,
            using: params
        )

        let parser = ParserBox()
        let authPacket = Self.makeAuthPacket(accessCode: accessCode)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: authPacket, completion: .contentProcessed { error in
                    if error != nil {
                        continuation.finish()
                        connection.cancel()
                    } else {
                        Self.receiveLoop(connection, parser, continuation)
                    }
                })
            case .failed, .cancelled:
                continuation.finish()
            default:
                break
            }
        }
        continuation.onTermination = { _ in connection.cancel() }
        connection.start(queue: DispatchQueue(label: "BambuKit.camera"))
        return stream
    }

    private static func receiveLoop(
        _ connection: NWConnection,
        _ parser: ParserBox,
        _ continuation: AsyncStream<Data>.Continuation
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data {
                for frame in parser.append(data) { continuation.yield(frame) }
            }
            if isComplete || error != nil {
                continuation.finish()
                connection.cancel()
                return
            }
            receiveLoop(connection, parser, continuation)
        }
    }

    /// Serializes parser access; all use happens on the single connection queue.
    private final class ParserBox: @unchecked Sendable {
        private var parser = JPEGStreamParser()
        func append(_ data: Data) -> [Data] { parser.append(data) }
    }
}

extension Data {
    fileprivate func padded(to length: Int) -> Data {
        count >= length ? prefix(length) : self + Data(repeating: 0, count: length - count)
    }
}
