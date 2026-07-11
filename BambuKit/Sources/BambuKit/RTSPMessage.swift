import Foundation

/// RTSP wire text (RFC 2326). Requests are built and serialized by the
/// client; responses and interleaved binary frames are pulled out of the
/// shared TLS byte stream by `RTSPStreamDemuxer`.
public struct RTSPHeader: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct RTSPRequest: Sendable, Equatable {
    public var method: String
    public var uri: String
    public var cseq: Int
    public var headers: [RTSPHeader]

    public init(method: String, uri: String, cseq: Int, headers: [RTSPHeader] = []) {
        self.method = method
        self.uri = uri
        self.cseq = cseq
        self.headers = headers
    }

    /// CSeq is emitted first; some servers reject requests where it trails.
    public func serialized() -> Data {
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        for header in headers { text += "\(header.name): \(header.value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}

public struct RTSPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [RTSPHeader]
    public var body: Data

    public init(statusCode: Int, headers: [RTSPHeader], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func value(forHeader name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func values(forHeader name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
}

public enum RTSPParseError: Error, Sendable, Equatable {
    case malformedResponse
    case oversizedMessage
}

/// Splits the shared RTSP/TCP byte stream into text responses and
/// '$'-prefixed interleaved binary frames (RFC 2326 §10.12), tolerating
/// arbitrary chunk boundaries. Server-initiated requests are consumed and
/// ignored. The RTSP analogue of `JPEGStreamParser`.
public struct RTSPStreamDemuxer: Sendable {
    public enum Event: Sendable, Equatable {
        case response(RTSPResponse)
        case interleaved(channel: UInt8, payload: Data)
    }

    private var buffer = Data()
    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
    private static let maxBufferedBytes = 1 << 20

    public init() {}

    public mutating func append(_ chunk: Data) throws(RTSPParseError) -> [Event] {
        buffer.append(chunk)
        var events: [Event] = []
        while !buffer.isEmpty {
            if buffer[buffer.startIndex] == UInt8(ascii: "$") {
                guard let event = consumeInterleavedFrame() else { break }
                events.append(event)
            } else {
                guard let event = try consumeMessage() else { break }
                if case .some(let response) = event { events.append(.response(response)) }
            }
        }
        return events
    }

    private mutating func consumeInterleavedFrame() -> Event? {
        guard buffer.count >= 4 else { return nil }
        let channel = byte(at: 1)
        let length = Int(byte(at: 2)) << 8 | Int(byte(at: 3))
        guard buffer.count >= 4 + length else { return nil }
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
        let payloadEnd = buffer.index(payloadStart, offsetBy: length)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        return .interleaved(channel: channel, payload: payload)
    }

    /// Returns nil when more bytes are needed, `.some(nil)` for a consumed
    /// server-initiated request, `.some(response)` for a response.
    private mutating func consumeMessage() throws(RTSPParseError) -> RTSPResponse?? {
        guard let terminatorRange = buffer.range(of: Self.headerTerminator) else {
            if buffer.count > Self.maxBufferedBytes { throw .oversizedMessage }
            return nil
        }

        let headText = String(decoding: buffer[buffer.startIndex..<terminatorRange.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let startLine = lines.removeFirst()

        var headers: [RTSPHeader] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append(RTSPHeader(
                String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            ))
        }
        let contentLength = headers
            .first { $0.name.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.value) } ?? 0

        let bodyStart = terminatorRange.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        let parts = startLine.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0].hasPrefix("RTSP/"), let code = Int(parts[1]) {
            return RTSPResponse(statusCode: code, headers: headers, body: body)
        }
        if parts.count >= 3, parts.last?.hasPrefix("RTSP/") == true {
            return .some(nil) // server-initiated request; consumed, not surfaced
        }
        throw .malformedResponse
    }

    private func byte(at offset: Int) -> UInt8 {
        buffer[buffer.index(buffer.startIndex, offsetBy: offset)]
    }
}
