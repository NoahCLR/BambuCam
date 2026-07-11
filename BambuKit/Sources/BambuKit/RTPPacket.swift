import Foundation

/// One parsed RTP packet (RFC 3550 §5.1). Returns nil for anything that is
/// not a plausible version-2 packet; CSRC list, header extension, and
/// padding are skipped so `payload` is exactly the codec payload.
public struct RTPPacket: Sendable, Equatable {
    public var payloadType: UInt8
    public var marker: Bool
    public var sequenceNumber: UInt16
    public var timestamp: UInt32
    public var payload: Data

    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }

        let hasPadding = bytes[0] & 0x20 != 0
        let hasExtension = bytes[0] & 0x10 != 0
        let csrcCount = Int(bytes[0] & 0x0F)

        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7F
        sequenceNumber = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16
            | UInt32(bytes[6]) << 8 | UInt32(bytes[7])

        var offset = 12 + csrcCount * 4
        guard bytes.count >= offset else { return nil }
        if hasExtension {
            guard bytes.count >= offset + 4 else { return nil }
            let extensionWords = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + extensionWords * 4
        }

        var end = bytes.count
        if hasPadding {
            let padding = Int(bytes[end - 1])
            guard padding > 0, end - padding >= offset else { return nil }
            end -= padding
        }
        guard end >= offset else { return nil }
        payload = Data(bytes[offset..<end])
    }
}
