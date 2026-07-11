import Foundation
import Testing
@testable import BambuKit

@Suite struct RTSPMessageTests {
    @Test func requestSerializesWithCSeqFirst() {
        let request = RTSPRequest(method: "OPTIONS",
                                  uri: "rtsps://192.168.1.50:322/streaming/live/1",
                                  cseq: 1,
                                  headers: [RTSPHeader("User-Agent", "BambuCam")])
        let expected = "OPTIONS rtsps://192.168.1.50:322/streaming/live/1 RTSP/1.0\r\n"
            + "CSeq: 1\r\n"
            + "User-Agent: BambuCam\r\n"
            + "\r\n"
        #expect(request.serialized() == Data(expected.utf8))
    }

    @Test func responseParsesAcrossArbitraryChunkBoundaries() throws {
        let wire = "RTSP/1.0 200 OK\r\nCSeq: 2\r\nSession: 12345;timeout=60\r\n\r\n"
        var demuxer = RTSPStreamDemuxer()
        var events: [RTSPStreamDemuxer.Event] = []
        for byte in Data(wire.utf8) { // worst case: one byte per chunk
            events += try demuxer.append(Data([byte]))
        }
        #expect(events.count == 1)
        guard case .response(let response) = events[0] else {
            Issue.record("expected a response event")
            return
        }
        #expect(response.statusCode == 200)
        #expect(response.value(forHeader: "Session") == "12345;timeout=60")
    }

    @Test func contentLengthBodyIsExtracted() throws {
        let body = "v=0\r\nm=video 0 RTP/AVP 96\r\n"
        let head = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        var demuxer = RTSPStreamDemuxer()

        // Head first, body split in two: no event until the body completes.
        #expect(try demuxer.append(Data(head.utf8)).isEmpty)
        #expect(try demuxer.append(Data(body.prefix(5).utf8)).isEmpty)
        let events = try demuxer.append(Data(body.dropFirst(5).utf8))
        guard case .response(let response) = events.first else {
            Issue.record("expected a response event")
            return
        }
        #expect(response.body == Data(body.utf8))
    }

    @Test func interleavedFrameBetweenResponsesKeepsOrder() throws {
        let response = "RTSP/1.0 200 OK\r\nCSeq: 4\r\n\r\n"
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = Data([0x24, 0x00, 0x00, UInt8(payload.count)]) + payload
        var demuxer = RTSPStreamDemuxer()

        let events = try demuxer.append(Data(response.utf8) + frame + Data(response.utf8))
        #expect(events.count == 3)
        #expect(events[1] == .interleaved(channel: 0, payload: payload))
    }

    @Test func interleavedFrameSplitAcrossChunks() throws {
        let payload = Data((0..<300).map { UInt8($0 % 256) }) // length needs both size bytes
        let frame = Data([0x24, 0x01, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]) + payload
        var demuxer = RTSPStreamDemuxer()

        #expect(try demuxer.append(frame.prefix(3)).isEmpty)
        #expect(try demuxer.append(frame.dropFirst(3).prefix(100)).isEmpty)
        let events = try demuxer.append(frame.dropFirst(103))
        #expect(events == [.interleaved(channel: 1, payload: payload)])
    }

    @Test func unauthorizedResponseExposesChallengeCaseInsensitively() throws {
        let wire = "RTSP/1.0 401 Unauthorized\r\n"
            + "CSeq: 2\r\n"
            + "WWW-Authenticate: Digest realm=\"printer\", nonce=\"abc\"\r\n\r\n"
        var demuxer = RTSPStreamDemuxer()
        let events = try demuxer.append(Data(wire.utf8))
        guard case .response(let response) = events.first else {
            Issue.record("expected a response event")
            return
        }
        #expect(response.statusCode == 401)
        #expect(response.value(forHeader: "www-authenticate") == "Digest realm=\"printer\", nonce=\"abc\"")
    }

    @Test func serverInitiatedRequestIsConsumedSilently() throws {
        let wire = "OPTIONS rtsps://192.168.1.50:322/ RTSP/1.0\r\nCSeq: 9\r\n\r\n"
            + "RTSP/1.0 200 OK\r\nCSeq: 5\r\n\r\n"
        var demuxer = RTSPStreamDemuxer()
        let events = try demuxer.append(Data(wire.utf8))
        #expect(events.count == 1)
        guard case .response(let response) = events[0] else {
            Issue.record("expected a response event")
            return
        }
        #expect(response.statusCode == 200)
    }

    @Test func garbageThrowsMalformed() {
        var demuxer = RTSPStreamDemuxer()
        #expect(throws: RTSPParseError.malformedResponse) {
            try demuxer.append(Data("not rtsp at all\r\n\r\n".utf8))
        }
    }
}
