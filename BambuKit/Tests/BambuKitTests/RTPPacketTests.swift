import Foundation
import Testing
@testable import BambuKit

@Suite struct RTPPacketTests {
    /// RFC 3550 §5.1 header layout: V=2, M=1, PT=96, seq 0x1234,
    /// ts 0x01020304, ssrc 0xDEADBEEF.
    @Test func parsesHeaderVector() throws {
        let data = Data([
            0x80, 0xE0, 0x12, 0x34,
            0x01, 0x02, 0x03, 0x04,
            0xDE, 0xAD, 0xBE, 0xEF,
            0xAA, 0xBB,
        ])
        let packet = try #require(RTPPacket(data: data))
        #expect(packet.marker)
        #expect(packet.payloadType == 96)
        #expect(packet.sequenceNumber == 0x1234)
        #expect(packet.timestamp == 0x0102_0304)
        #expect(packet.payload == Data([0xAA, 0xBB]))
    }

    @Test func skipsCSRCList() throws {
        var data = Data([0x82, 0x60, 0x00, 0x01, 0, 0, 0, 1, 0, 0, 0, 2]) // CC=2
        data += Data([0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x22, 0x22])    // two CSRCs
        data += Data([0xCC])
        let packet = try #require(RTPPacket(data: data))
        #expect(!packet.marker)
        #expect(packet.payload == Data([0xCC]))
    }

    @Test func skipsHeaderExtension() throws {
        var data = Data([0x90, 0x60, 0x00, 0x01, 0, 0, 0, 1, 0, 0, 0, 2]) // X=1
        data += Data([0xBE, 0xDE, 0x00, 0x01, 0x01, 0x02, 0x03, 0x04])    // 1-word extension
        data += Data([0xCC])
        let packet = try #require(RTPPacket(data: data))
        #expect(packet.payload == Data([0xCC]))
    }

    @Test func stripsPadding() throws {
        var data = Data([0xA0, 0x60, 0x00, 0x01, 0, 0, 0, 1, 0, 0, 0, 2]) // P=1
        data += Data([0xCC, 0x00, 0x00, 0x03]) // payload + 3 padding bytes
        let packet = try #require(RTPPacket(data: data))
        #expect(packet.payload == Data([0xCC]))
    }

    @Test func rejectsTruncatedAndWrongVersion() {
        #expect(RTPPacket(data: Data([0x80, 0x60, 0x00])) == nil)
        var wrongVersion = Data(repeating: 0, count: 13)
        wrongVersion[0] = 0x40 // V=1
        #expect(RTPPacket(data: wrongVersion) == nil)
    }
}
