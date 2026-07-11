import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// MQTT link to the printer: status reports in, commands out.
///
/// This intentionally uses the small MQTT 3.1.1 subset the printer speaks
/// instead of MQTTNIO. MQTTNIO accepts a TLS configuration but has no public
/// way to install a certificate-pin callback. Here the pinned certificate is
/// verified during the very TLS connection that subsequently carries the
/// access code.
public actor PrinterClient {
    private let hostname: String
    private let port: Int
    private let accessCode: String
    private let serial: String
    private let certificateDER: Data
    private var channel: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var accumulator = StatusAccumulator()
    private let incomingReports: AsyncStream<Data>
    private let incomingReportsContinuation: AsyncStream<Data>.Continuation

    public init(hostname: String, accessCode: String, serial: String, certificateDER: Data,
                port: Int = 8883) {
        self.hostname = hostname
        self.port = port
        self.accessCode = accessCode
        self.serial = serial
        self.certificateDER = certificateDER
        (incomingReports, incomingReportsContinuation) = AsyncStream.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(1)
        )
    }

    public func connect() async throws {
        if channel != nil || eventLoopGroup != nil {
            await disconnect()
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        let connackPromise = eventLoop.makePromise(of: Void.self)
        let subackPromise = eventLoop.makePromise(of: Void.self)
        let handshake = MQTTHandshake(connackPromise: connackPromise, subackPromise: subackPromise)
        let expectedCertificateDER = certificateDER
        let reportContinuation = incomingReportsContinuation

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        // Keep certificate verification enabled so NIOSSL invokes the custom
        // verifier. It compares the peer's leaf certificate byte-for-byte
        // with the certificate accepted during pairing; no CA, hostname, or
        // arbitrary self-signed certificate can satisfy this callback.
        tlsConfiguration.certificateVerification = .noHostnameVerification
        let tlsContext = try NIOSSLContext(configuration: tlsConfiguration)
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.seconds(5))
            .channelInitializer { channel in
                do {
                    let tlsHandler = try NIOSSLClientHandler(
                        context: tlsContext,
                        serverHostname: nil,
                        customVerificationCallback: { certificates, promise in
                            guard let leaf = certificates.first,
                                  let der = try? leaf.toDERBytes(),
                                  Data(der) == expectedCertificateDER
                            else {
                                promise.succeed(.failed)
                                return
                            }
                            promise.succeed(.certificateVerified)
                        }
                    )
                    let responseHandler = MQTTResponseHandler(
                        handshake: handshake,
                        onPublish: { [reportContinuation] data in
                            reportContinuation.yield(data)
                        },
                        onClosed: { [reportContinuation] in
                            reportContinuation.finish()
                        }
                    )
                    try channel.pipeline.syncOperations.addHandler(tlsHandler)
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(MQTTFrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(responseHandler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        var connectedChannel: Channel?
        do {
            let channel = try await bootstrap.connect(host: hostname, port: port).get()
            connectedChannel = channel

            try await channel.writeAndFlush(
                MQTTWire.connect(clientID: "BambuCam-\(UUID().uuidString.prefix(8))",
                                 username: "bblp", password: accessCode)
            ).get()
            try await connackPromise.futureResult.get()

            try await channel.writeAndFlush(
                MQTTWire.subscribe(packetID: 1, topic: "device/\(serial)/report")
            ).get()
            try await subackPromise.futureResult.get()

            // AsyncStream buffers the most recent report, so this request is
            // safe even if the status consumer starts immediately afterwards.
            try await channel.writeAndFlush(
                MQTTWire.publish(
                    topic: "device/\(serial)/request",
                    payload: #"{"pushing": { "sequence_id": 1, "command": "pushall"}, "user_id":"1234567890"}"#
                )
            ).get()

            self.channel = channel
            self.eventLoopGroup = eventLoopGroup
        } catch {
            handshake.failAll(error)
            if let connectedChannel {
                try? await connectedChannel.close().get()
            }
            try? await eventLoopGroup.shutdownGracefully()
            incomingReportsContinuation.finish()
            throw error
        }
    }

    public func statusUpdates() -> AsyncStream<PrinterStatus> {
        let incomingReports = incomingReports
        let (stream, continuation) = AsyncStream.makeStream(of: PrinterStatus.self,
            bufferingPolicy: .bufferingNewest(1))
        let task = Task { [weak self] in
            for await report in incomingReports {
                guard let self else { break }
                if let status = await self.ingest(report) {
                    continuation.yield(status)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func ingest(_ data: Data) -> PrinterStatus? {
        accumulator.ingest(data)
    }

    public func send(_ command: PrinterCommand) async throws {
        guard let channel else { throw PrinterClientError.notConnected }
        // The printer's broker (P1S, at least on firmware 01.10) executes QoS 1
        // publishes but never sends the PUBACK, so an .atLeastOnce publish awaits
        // forever. The printer acks at the application level instead, with a
        // reply on device/<serial>/report.
        try await channel.writeAndFlush(
            MQTTWire.publish(topic: "device/\(serial)/request", payload: command.payload)
        ).get()
    }

    public func disconnect() async {
        let channel = channel
        let eventLoopGroup = eventLoopGroup
        self.channel = nil
        self.eventLoopGroup = nil

        if let channel {
            try? await channel.close().get()
        }
        if let eventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }
        incomingReportsContinuation.finish()
    }
}

public enum PrinterClientError: Error {
    case notConnected
}

private enum MQTTWire {
    static func connect(clientID: String, username: String, password: String) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 64 + clientID.utf8.count + password.utf8.count)
        writeString("MQTT", to: &body)
        body.writeInteger(UInt8(4)) // MQTT 3.1.1
        body.writeInteger(UInt8(0b1100_0010)) // username, password, clean session
        body.writeInteger(UInt16(60), endianness: .big)
        writeString(clientID, to: &body)
        writeString(username, to: &body)
        writeString(password, to: &body)
        return packet(type: 1, flags: 0, body: body)
    }

    static func subscribe(packetID: UInt16, topic: String) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 8 + topic.utf8.count)
        body.writeInteger(packetID, endianness: .big)
        writeString(topic, to: &body)
        body.writeInteger(UInt8(0)) // requested QoS 0
        return packet(type: 8, flags: 0b0010, body: body)
    }

    static func publish(topic: String, payload: String) -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(capacity: 4 + topic.utf8.count + payload.utf8.count)
        writeString(topic, to: &body)
        body.writeBytes(payload.utf8)
        return packet(type: 3, flags: 0, body: body)
    }

    private static func packet(type: UInt8, flags: UInt8, body: ByteBuffer) -> ByteBuffer {
        var packet = ByteBufferAllocator().buffer(capacity: body.readableBytes + 5)
        packet.writeInteger((type << 4) | flags)
        writeRemainingLength(body.readableBytes, to: &packet)
        var body = body
        packet.writeBuffer(&body)
        return packet
    }

    private static func writeString(_ string: String, to buffer: inout ByteBuffer) {
        let bytes = Array(string.utf8)
        precondition(bytes.count <= Int(UInt16.max), "MQTT strings must fit in UInt16")
        buffer.writeInteger(UInt16(bytes.count), endianness: .big)
        buffer.writeBytes(bytes)
    }

    private static func writeRemainingLength(_ length: Int, to buffer: inout ByteBuffer) {
        precondition((0...268_435_455).contains(length), "MQTT packet is too large")
        var value = length
        repeat {
            var encoded = UInt8(value % 128)
            value /= 128
            if value > 0 { encoded |= 0x80 }
            buffer.writeInteger(encoded)
        } while value > 0
    }
}

private struct MQTTInboundPacket {
    let type: UInt8
    let flags: UInt8
    var payload: ByteBuffer
}

private enum MQTTFrameDecoderError: Error {
    case malformedRemainingLength
}

private struct MQTTFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = MQTTInboundPacket

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let start = buffer.readerIndex
        guard let header: UInt8 = buffer.getInteger(at: start) else { return .needMoreData }

        var cursor = start + 1
        var multiplier = 1
        var remainingLength = 0
        var complete = false
        for _ in 0..<4 {
            guard let encoded: UInt8 = buffer.getInteger(at: cursor) else { return .needMoreData }
            cursor += 1
            remainingLength += Int(encoded & 0x7f) * multiplier
            if encoded & 0x80 == 0 {
                complete = true
                break
            }
            multiplier *= 128
        }
        guard complete else { throw MQTTFrameDecoderError.malformedRemainingLength }

        let headerLength = cursor - start
        guard buffer.readableBytes >= headerLength + remainingLength else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: headerLength)
        guard let payload = buffer.readSlice(length: remainingLength) else { return .needMoreData }
        context.fireChannelRead(wrapInboundOut(MQTTInboundPacket(
            type: header >> 4,
            flags: header & 0x0f,
            payload: payload
        )))
        return .continue
    }
}

private final class MQTTResponseHandler: ChannelInboundHandler {
    typealias InboundIn = MQTTInboundPacket

    private let handshake: MQTTHandshake
    private let onPublish: @Sendable (Data) -> Void
    private let onClosed: @Sendable () -> Void

    init(handshake: MQTTHandshake,
         onPublish: @escaping @Sendable (Data) -> Void, onClosed: @escaping @Sendable () -> Void) {
        self.handshake = handshake
        self.onPublish = onPublish
        self.onClosed = onClosed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        switch packet.type {
        case 2:
            handleConnack(packet)
        case 3:
            handlePublish(packet)
        case 9:
            succeedSuback()
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        handshake.failAll(MQTTResponseError.connectionClosed)
        onClosed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        handshake.failAll(error)
        context.close(promise: nil)
    }

    private func handleConnack(_ packet: MQTTInboundPacket) {
        guard packet.payload.readableBytes >= 2,
              let returnCode: UInt8 = packet.payload.getInteger(at: packet.payload.readerIndex + 1),
              returnCode == 0
        else {
            handshake.failConnack(MQTTResponseError.connectionRefused)
            return
        }
        handshake.succeedConnack()
    }

    private func succeedSuback() {
        handshake.succeedSuback()
    }

    private func handlePublish(_ packet: MQTTInboundPacket) {
        var payload = packet.payload
        guard let topicLength: UInt16 = payload.readInteger(endianness: .big),
              payload.readableBytes >= Int(topicLength)
        else { return }
        payload.moveReaderIndex(forwardBy: Int(topicLength))

        let qos = (packet.flags >> 1) & 0b11
        if qos > 0 {
            guard payload.readInteger(endianness: .big) as UInt16? != nil else { return }
        }
        onPublish(Data(payload.readableBytesView))
    }
}

/// Serialises completion of the two handshake promises. A channel callback and
/// the actor's connection error path can race when a TLS handshake fails.
private final class MQTTHandshake: @unchecked Sendable {
    private let lock = NSLock()
    private let connackPromise: EventLoopPromise<Void>
    private let subackPromise: EventLoopPromise<Void>
    private var connackCompleted = false
    private var subackCompleted = false

    init(connackPromise: EventLoopPromise<Void>, subackPromise: EventLoopPromise<Void>) {
        self.connackPromise = connackPromise
        self.subackPromise = subackPromise
    }

    func succeedConnack() {
        guard takeConnackCompletion() else { return }
        connackPromise.succeed()
    }

    func failConnack(_ error: Error) {
        guard takeConnackCompletion() else { return }
        connackPromise.fail(error)
    }

    func succeedSuback() {
        guard takeSubackCompletion() else { return }
        subackPromise.succeed()
    }

    func failAll(_ error: Error) {
        if takeConnackCompletion() { connackPromise.fail(error) }
        if takeSubackCompletion() { subackPromise.fail(error) }
    }

    private func takeConnackCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !connackCompleted else { return false }
        connackCompleted = true
        return true
    }

    private func takeSubackCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !subackCompleted else { return false }
        subackCompleted = true
        return true
    }
}

private enum MQTTResponseError: Error {
    case connectionClosed
    case connectionRefused
}
