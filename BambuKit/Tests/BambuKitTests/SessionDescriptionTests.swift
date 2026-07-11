import Foundation
import Testing
@testable import BambuKit

@Suite struct SessionDescriptionTests {
    private let sps = Data([0x67, 0x42, 0x80, 0x1E, 0xDA, 0x01, 0x40, 0x16, 0xEC, 0x04])
    private let pps = Data([0x68, 0xCE, 0x06, 0xE2])

    private func x1StyleSDP(sprop: Bool = true) -> String {
        let fmtp = sprop
            ? "a=fmtp:96 packetization-mode=1;profile-level-id=42801e;"
                + "sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())\r\n"
            : "a=fmtp:96 packetization-mode=1\r\n"
        return "v=0\r\n"
            + "o=- 0 0 IN IP4 192.168.1.50\r\n"
            + "s=streamed by Bambu\r\n"
            + "t=0 0\r\n"
            + "a=control:*\r\n"
            + "m=video 0 RTP/AVP 96\r\n"
            + "a=rtpmap:96 H264/90000\r\n"
            + fmtp
            + "a=control:track1\r\n"
    }

    @Test func parsesParameterSetsControlAndPayloadType() throws {
        let description = try #require(SessionDescription(sdp: x1StyleSDP()))
        #expect(description.videoPayloadType == 96)
        #expect(description.sps == sps)
        #expect(description.pps == pps)
        #expect(description.videoControl == "track1")
    }

    @Test func relativeControlResolvesAgainstBase() throws {
        let description = try #require(SessionDescription(sdp: x1StyleSDP()))
        #expect(description.resolvedVideoControl(relativeTo: "rtsps://192.168.1.50:322/streaming/live/1")
            == "rtsps://192.168.1.50:322/streaming/live/1/track1")
    }

    @Test func absoluteControlPassesThrough() throws {
        let sdp = x1StyleSDP().replacingOccurrences(
            of: "a=control:track1",
            with: "a=control:rtsps://192.168.1.50:322/streaming/live/1/track1"
        )
        let description = try #require(SessionDescription(sdp: sdp))
        #expect(description.resolvedVideoControl(relativeTo: "rtsps://192.168.1.50:322/streaming/live/1")
            == "rtsps://192.168.1.50:322/streaming/live/1/track1")
    }

    @Test func missingControlMeansBaseURI() throws {
        let sdp = "v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
        let description = try #require(SessionDescription(sdp: sdp))
        #expect(description.resolvedVideoControl(relativeTo: "rtsps://host/live") == "rtsps://host/live")
    }

    @Test func sdpWithoutSpropStillParses() throws {
        let description = try #require(SessionDescription(sdp: x1StyleSDP(sprop: false)))
        #expect(description.sps == nil)
        #expect(description.pps == nil)
        #expect(description.videoPayloadType == 96)
    }

    @Test func sdpWithoutVideoSectionIsRejected() {
        #expect(SessionDescription(sdp: "v=0\r\nm=audio 0 RTP/AVP 0\r\n") == nil)
    }
}
