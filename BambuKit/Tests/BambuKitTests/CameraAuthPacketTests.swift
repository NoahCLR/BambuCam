import Foundation
import Testing
@testable import BambuKit

@Suite struct CameraAuthPacketTests {
    // Python reference: struct.pack("IIL", 0x40, 0x3000, 0x0)
    //   + b"bblp".ljust(32, b"\x00") + access_code.ljust(32, b"\x00")
    // = 16-byte little-endian header + 32 + 32 = 80 bytes.
    @Test func packetMatchesPythonReference() {
        let packet = CameraClient.makeAuthPacket(accessCode: "12345678")
        #expect(packet.count == 80)

        var expected = Data()
        expected.append(contentsOf: [0x40, 0x00, 0x00, 0x00])              // UInt32 0x40
        expected.append(contentsOf: [0x00, 0x30, 0x00, 0x00])              // UInt32 0x3000
        expected.append(contentsOf: [UInt8](repeating: 0, count: 8))       // UInt64 0x0
        expected.append("bblp".data(using: .ascii)!)
        expected.append(Data(repeating: 0, count: 32 - 4))
        expected.append("12345678".data(using: .ascii)!)
        expected.append(Data(repeating: 0, count: 32 - 8))
        #expect(packet == expected)
    }
}
