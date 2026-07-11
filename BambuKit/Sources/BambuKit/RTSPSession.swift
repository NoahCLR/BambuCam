import Foundation

public enum RTSPSessionError: Error, Sendable, Equatable {
    case malformedStream
    case unauthorized
    case requestFailed(method: String, statusCode: Int)
    case invalidSessionDescription
}

/// Drives one RTSP playback session as a pure state machine: bytes and
/// clock ticks in, `Output` values out. The caller owns the socket and the
/// keepalive timer; this type owns the protocol (RFC 2326):
/// OPTIONS → DESCRIBE → SETUP (TCP-interleaved) → PLAY → frames, with one
/// authentication retry per request and GET_PARAMETER keepalives.
public struct RTSPSession {
    public enum Output: Sendable, Equatable {
        case send(Data)
        case frame(H264AccessUnit)
        case failure(RTSPSessionError)
    }

    private enum State {
        case idle
        case awaitingOptions
        case awaitingDescribe
        case awaitingSetup
        case awaitingPlay
        case streaming
        case failed
        case tornDown
    }

    /// Session timeout/2 once SETUP reports one; 30s until then.
    public private(set) var keepaliveInterval: Duration = .seconds(30)

    private let uri: String
    private let username: String
    private let password: String
    private let cnonce: String

    private var state: State = .idle
    private var cseq = 0
    private var demuxer = RTSPStreamDemuxer()
    private var depacketizer = H264Depacketizer()
    private var challenge: String?
    private var nonceCount = 0
    private var didRetryCurrentRequest = false
    private var lastRequest: (method: String, uri: String, extraHeaders: [RTSPHeader])?
    private var sessionID: String?
    private var supportsGetParameter = false
    private var videoPayloadType: UInt8?
    private var rtpChannel: UInt8 = 0

    public init(uri: String, username: String, password: String,
                cnonce: String = UUID().uuidString) {
        self.uri = uri
        self.username = username
        self.password = password
        self.cnonce = cnonce
    }

    public mutating func start() -> [Output] {
        guard case .idle = state else { return [] }
        state = .awaitingOptions
        return [request(method: "OPTIONS", uri: uri)]
    }

    public mutating func receive(_ chunk: Data) -> [Output] {
        switch state {
        case .failed, .tornDown, .idle: return []
        default: break
        }

        let events: [RTSPStreamDemuxer.Event]
        do {
            events = try demuxer.append(chunk)
        } catch {
            return [fail(.malformedStream)]
        }

        var outputs: [Output] = []
        for event in events {
            switch event {
            case .interleaved(let channel, let payload):
                outputs += handleInterleaved(channel: channel, payload: payload)
            case .response(let response):
                outputs += handleResponse(response)
            }
            if case .failed = state { break }
        }
        return outputs
    }

    public mutating func keepalive() -> [Output] {
        guard case .streaming = state, let sessionID else { return [] }
        let method = supportsGetParameter ? "GET_PARAMETER" : "OPTIONS"
        return [request(method: method, uri: uri, extraHeaders: [RTSPHeader("Session", sessionID)])]
    }

    public mutating func teardown() -> [Output] {
        switch state {
        case .idle, .failed, .tornDown: return []
        default: break
        }
        let headers = sessionID.map { [RTSPHeader("Session", $0)] } ?? []
        defer { state = .tornDown }
        return [request(method: "TEARDOWN", uri: uri, extraHeaders: headers)]
    }

    // MARK: - Responses

    private mutating func handleResponse(_ response: RTSPResponse) -> [Output] {
        if response.statusCode == 401 { return handleUnauthorized(response) }
        guard (200..<300).contains(response.statusCode) else {
            // Keepalive replies are advisory; anything else is fatal.
            if case .streaming = state { return [] }
            return [fail(.requestFailed(method: lastRequest?.method ?? "?",
                                        statusCode: response.statusCode))]
        }

        switch state {
        case .awaitingOptions:
            supportsGetParameter = response.value(forHeader: "Public")?
                .contains("GET_PARAMETER") ?? false
            state = .awaitingDescribe
            return [request(method: "DESCRIBE", uri: uri,
                            extraHeaders: [RTSPHeader("Accept", "application/sdp")])]

        case .awaitingDescribe:
            let sdp = String(decoding: response.body, as: UTF8.self)
            guard let description = SessionDescription(sdp: sdp) else {
                return [fail(.invalidSessionDescription)]
            }
            videoPayloadType = description.videoPayloadType
            depacketizer = H264Depacketizer(sps: description.sps, pps: description.pps)
            state = .awaitingSetup
            return [request(method: "SETUP",
                            uri: description.resolvedVideoControl(relativeTo: uri),
                            extraHeaders: [RTSPHeader("Transport", "RTP/AVP/TCP;unicast;interleaved=0-1")])]

        case .awaitingSetup:
            parseSessionHeader(response.value(forHeader: "Session"))
            parseTransportHeader(response.value(forHeader: "Transport"))
            state = .awaitingPlay
            var headers = [RTSPHeader("Range", "npt=0.000-")]
            if let sessionID { headers.append(RTSPHeader("Session", sessionID)) }
            return [request(method: "PLAY", uri: uri, extraHeaders: headers)]

        case .awaitingPlay:
            state = .streaming
            return []

        case .streaming: // keepalive reply
            return []

        case .idle, .failed, .tornDown:
            return []
        }
    }

    private mutating func handleUnauthorized(_ response: RTSPResponse) -> [Output] {
        guard !didRetryCurrentRequest,
              let selected = RTSPAuthentication.selectChallenge(
                  from: response.values(forHeader: "WWW-Authenticate")),
              let last = lastRequest
        else { return [fail(.unauthorized)] }

        challenge = selected
        didRetryCurrentRequest = true
        return [request(method: last.method, uri: last.uri,
                        extraHeaders: last.extraHeaders, isRetry: true)]
    }

    // MARK: - Interleaved RTP

    private mutating func handleInterleaved(channel: UInt8, payload: Data) -> [Output] {
        guard case .streaming = state, channel == rtpChannel,
              let packet = RTPPacket(data: payload)
        else { return [] } // RTCP channel and pre-PLAY stray data are ignored
        if let expected = videoPayloadType, packet.payloadType != expected { return [] }
        return depacketizer.append(packet).map { .frame($0) }
    }

    // MARK: - Helpers

    private mutating func request(method: String, uri: String,
                                  extraHeaders: [RTSPHeader] = [],
                                  isRetry: Bool = false) -> Output {
        cseq += 1
        if !isRetry { didRetryCurrentRequest = false }
        lastRequest = (method, uri, extraHeaders)

        var headers = [RTSPHeader("User-Agent", "BambuCam")]
        if let challenge {
            nonceCount += 1
            if let authorization = RTSPAuthentication.authorizationHeader(
                challenge: challenge, method: method, uri: uri,
                username: username, password: password,
                cnonce: cnonce, nonceCount: nonceCount) {
                headers.append(RTSPHeader("Authorization", authorization))
            }
        }
        headers += extraHeaders
        return .send(RTSPRequest(method: method, uri: uri, cseq: cseq, headers: headers).serialized())
    }

    private mutating func fail(_ error: RTSPSessionError) -> Output {
        state = .failed
        return .failure(error)
    }

    // Session: <id>[;timeout=<seconds>]
    private mutating func parseSessionHeader(_ value: String?) {
        guard let value else { return }
        let parts = value.split(separator: ";")
        guard let id = parts.first?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return }
        sessionID = id
        for part in parts.dropFirst() {
            let parameter = part.trimmingCharacters(in: .whitespaces)
            if parameter.lowercased().hasPrefix("timeout="),
               let timeout = Int(parameter.dropFirst("timeout=".count)), timeout > 0 {
                keepaliveInterval = .seconds(max(1, min(timeout, 60) / 2))
            }
        }
    }

    // Transport: RTP/AVP/TCP;unicast;interleaved=<rtp>-<rtcp>
    private mutating func parseTransportHeader(_ value: String?) {
        guard let value else { return }
        for parameter in value.split(separator: ";") {
            let parameter = parameter.trimmingCharacters(in: .whitespaces)
            guard parameter.lowercased().hasPrefix("interleaved=") else { continue }
            let channels = parameter.dropFirst("interleaved=".count).split(separator: "-")
            if let first = channels.first, let channel = UInt8(first) { rtpChannel = channel }
        }
    }
}
