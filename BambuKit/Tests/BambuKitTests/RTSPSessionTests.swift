import Foundation
import Testing
@testable import BambuKit

private let presentationURI = "rtsps://192.168.1.50:322/streaming/live/1"
private let sps = Data([0x67, 0x42, 0x80, 0x1E])
private let pps = Data([0x68, 0xCE, 0x06, 0xE2])

private func response(_ status: String, headers: [String] = [], body: String = "") -> Data {
    var text = "RTSP/1.0 \(status)\r\n"
    for header in headers { text += header + "\r\n" }
    if !body.isEmpty { text += "Content-Length: \(body.utf8.count)\r\n" }
    text += "\r\n" + body
    return Data(text.utf8)
}

private func describeSDP() -> String {
    "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
        + "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())\r\n"
        + "a=control:track1\r\n"
}

private func sentText(_ outputs: [RTSPSession.Output]) -> String {
    guard case .send(let data) = outputs.first else { return "" }
    return String(decoding: data, as: UTF8.self)
}

/// An interleaved RTP frame on channel 0 carrying one single-NAL payload.
private func interleavedRTP(seq: UInt16, timestamp: UInt32, marker: Bool, nalUnit: [UInt8]) -> Data {
    var rtp = Data([0x80, marker ? 0xE0 : 0x60, UInt8(seq >> 8), UInt8(seq & 0xFF)])
    withUnsafeBytes(of: timestamp.bigEndian) { rtp.append(contentsOf: $0) }
    rtp += Data([0, 0, 0, 1]) // ssrc
    rtp += Data(nalUnit)
    return Data([0x24, 0x00, UInt8(rtp.count >> 8), UInt8(rtp.count & 0xFF)]) + rtp
}

/// Drives a session through the full handshake and returns it streaming.
private func streamingSession() -> RTSPSession {
    var session = RTSPSession(uri: presentationURI, username: "bblp", password: "code",
                              cnonce: "0a4f113b")
    _ = session.start()
    _ = session.receive(response("200 OK", headers: ["CSeq: 1", "Public: OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER"]))
    _ = session.receive(response("200 OK", headers: ["CSeq: 2"], body: describeSDP()))
    _ = session.receive(response("200 OK", headers: ["CSeq: 3", "Session: 12345;timeout=60",
                                                     "Transport: RTP/AVP/TCP;unicast;interleaved=0-1"]))
    _ = session.receive(response("200 OK", headers: ["CSeq: 4", "Session: 12345"]))
    return session
}

@Suite struct RTSPSessionTests {
    @Test func handshakeScriptSendsExpectedRequests() {
        var session = RTSPSession(uri: presentationURI, username: "bblp", password: "code",
                                  cnonce: "0a4f113b")

        let options = sentText(session.start())
        #expect(options.hasPrefix("OPTIONS \(presentationURI) RTSP/1.0\r\nCSeq: 1\r\n"))

        let describe = sentText(session.receive(response("200 OK", headers: ["CSeq: 1", "Public: DESCRIBE, SETUP, PLAY, GET_PARAMETER"])))
        #expect(describe.hasPrefix("DESCRIBE \(presentationURI) RTSP/1.0\r\nCSeq: 2\r\n"))
        #expect(describe.contains("Accept: application/sdp\r\n"))

        let setup = sentText(session.receive(response("200 OK", headers: ["CSeq: 2"], body: describeSDP())))
        #expect(setup.hasPrefix("SETUP \(presentationURI)/track1 RTSP/1.0\r\nCSeq: 3\r\n"))
        #expect(setup.contains("Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"))

        let play = sentText(session.receive(response("200 OK", headers: ["CSeq: 3", "Session: 12345;timeout=60",
                                                                         "Transport: RTP/AVP/TCP;unicast;interleaved=0-1"])))
        #expect(play.hasPrefix("PLAY \(presentationURI) RTSP/1.0\r\nCSeq: 4\r\n"))
        #expect(play.contains("Session: 12345\r\n"))
        #expect(play.contains("Range: npt=0.000-\r\n"))
        #expect(session.keepaliveInterval == .seconds(30))

        #expect(session.receive(response("200 OK", headers: ["CSeq: 4"])).isEmpty)
    }

    @Test func digestChallengeRetriesRequestWithAuthorization() {
        var session = RTSPSession(uri: presentationURI, username: "bblp", password: "code",
                                  cnonce: "0a4f113b")
        _ = session.start()
        let challenge = "Digest realm=\"printer\", nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", qop=\"auth\""
        let retry = sentText(session.receive(response("401 Unauthorized",
                                                      headers: ["CSeq: 1", "WWW-Authenticate: \(challenge)"])))

        #expect(retry.hasPrefix("OPTIONS \(presentationURI) RTSP/1.0\r\nCSeq: 2\r\n"))
        let expected = RTSPAuthentication.authorizationHeader(
            challenge: challenge, method: "OPTIONS", uri: presentationURI,
            username: "bblp", password: "code", cnonce: "0a4f113b", nonceCount: 1)!
        #expect(retry.contains("Authorization: \(expected)\r\n"))

        // Later requests keep authenticating with an incremented nonce count.
        let describe = sentText(session.receive(response("200 OK", headers: ["CSeq: 2"])))
        #expect(describe.contains("Authorization: Digest "))
        #expect(describe.contains("nc=00000002"))
    }

    @Test func secondUnauthorizedFails() {
        var session = RTSPSession(uri: presentationURI, username: "bblp", password: "wrong")
        _ = session.start()
        let challenge401 = response("401 Unauthorized",
                                    headers: ["CSeq: 1", "WWW-Authenticate: Digest realm=\"r\", nonce=\"n\""])
        _ = session.receive(challenge401)
        #expect(session.receive(challenge401) == [.failure(.unauthorized)])
    }

    @Test func nonSuccessSetupFails() {
        var session = RTSPSession(uri: presentationURI, username: "bblp", password: "code")
        _ = session.start()
        _ = session.receive(response("200 OK", headers: ["CSeq: 1"]))
        _ = session.receive(response("200 OK", headers: ["CSeq: 2"], body: describeSDP()))
        let outputs = session.receive(response("461 Unsupported Transport", headers: ["CSeq: 3"]))
        #expect(outputs == [.failure(.requestFailed(method: "SETUP", statusCode: 461))])
        // A failed session stops reacting entirely.
        #expect(session.receive(response("200 OK", headers: ["CSeq: 4"])).isEmpty)
    }

    @Test func interleavedRTPBecomesFrames() {
        var session = streamingSession()
        #expect(session.receive(interleavedRTP(seq: 1, timestamp: 100, marker: false,
                                               nalUnit: [0x65, 0x01])).isEmpty)
        let outputs = session.receive(interleavedRTP(seq: 2, timestamp: 100, marker: true,
                                                     nalUnit: [0x41, 0x02]))
        guard case .frame(let unit)? = outputs.first else {
            Issue.record("expected a frame output")
            return
        }
        #expect(unit.isIDR)
        #expect(unit.sps == sps)
        #expect(unit.rtpTimestamp == 100)
    }

    @Test func rtcpChannelIsIgnored() {
        var session = streamingSession()
        var frame = interleavedRTP(seq: 1, timestamp: 100, marker: true, nalUnit: [0x65, 0x01])
        frame[1] = 0x01 // rewrite the channel byte to the RTCP channel
        #expect(session.receive(frame).isEmpty)
    }

    @Test func keepaliveUsesGetParameterWithSession() {
        var session = streamingSession()
        let keepalive = sentText(session.keepalive())
        #expect(keepalive.hasPrefix("GET_PARAMETER \(presentationURI) RTSP/1.0\r\n"))
        #expect(keepalive.contains("Session: 12345\r\n"))
        // The 200 reply must not disturb streaming.
        #expect(session.receive(response("200 OK", headers: ["CSeq: 6", "Session: 12345"])).isEmpty)
    }

    @Test func keepaliveFallsBackToOptions() {
        var session = RTSPSession(uri: presentationURI, username: "bblp", password: "code")
        _ = session.start()
        _ = session.receive(response("200 OK", headers: ["CSeq: 1", "Public: DESCRIBE, SETUP, PLAY"]))
        _ = session.receive(response("200 OK", headers: ["CSeq: 2"], body: describeSDP()))
        _ = session.receive(response("200 OK", headers: ["CSeq: 3", "Session: 9;timeout=30"]))
        _ = session.receive(response("200 OK", headers: ["CSeq: 4"]))
        #expect(session.keepaliveInterval == .seconds(15))
        #expect(sentText(session.keepalive()).hasPrefix("OPTIONS "))
    }

    @Test func teardownSendsSessionAndStops() {
        var session = streamingSession()
        let teardown = sentText(session.teardown())
        #expect(teardown.hasPrefix("TEARDOWN \(presentationURI) RTSP/1.0\r\n"))
        #expect(teardown.contains("Session: 12345\r\n"))
        #expect(session.keepalive().isEmpty)
        #expect(session.receive(interleavedRTP(seq: 3, timestamp: 200, marker: true,
                                               nalUnit: [0x41, 0x03])).isEmpty)
    }

    @Test func malformedStreamFails() {
        var session = RTSPSession(uri: presentationURI, username: "bblp", password: "code")
        _ = session.start()
        #expect(session.receive(Data("garbage\r\n\r\n".utf8)) == [.failure(.malformedStream)])
    }
}
