import Foundation

/// Reassembles H.264 access units from RTP packets (RFC 6184): single NAL
/// units (types 1–23), STAP-A aggregates (24), and FU-A fragments (28).
/// An access unit completes on the RTP marker bit, with a timestamp change
/// as fallback for servers that do not set it. In-band SPS/PPS are captured
/// as parameter sets and excluded from unit payloads (they travel on
/// `H264AccessUnit.sps/pps` instead). A sequence-number gap drops the unit
/// in progress and resynchronizes at the next unit boundary.
public struct H264Depacketizer: Sendable {
    public private(set) var sps: Data?
    public private(set) var pps: Data?

    private var pendingNALUnits: [Data] = []
    private var fragmentBuffer: Data?
    private var currentTimestamp: UInt32?
    private var expectedSequenceNumber: UInt16?

    public init(sps: Data? = nil, pps: Data? = nil) {
        self.sps = sps
        self.pps = pps
    }

    /// Usually 0 or 1 units; 2 when one packet both closes the previous
    /// timestamp's unit and carries the marker for its own.
    public mutating func append(_ packet: RTPPacket) -> [H264AccessUnit] {
        guard !packet.payload.isEmpty else { return [] }
        var completed: [H264AccessUnit] = []

        if let expected = expectedSequenceNumber, packet.sequenceNumber != expected {
            pendingNALUnits.removeAll()
            fragmentBuffer = nil
        }
        expectedSequenceNumber = packet.sequenceNumber &+ 1

        if let timestamp = currentTimestamp, timestamp != packet.timestamp {
            if let unit = finishAccessUnit(timestamp: timestamp) { completed.append(unit) }
            fragmentBuffer = nil
        }
        currentTimestamp = packet.timestamp

        consume(payload: [UInt8](packet.payload))

        if packet.marker, let unit = finishAccessUnit(timestamp: packet.timestamp) {
            completed.append(unit)
        }
        return completed
    }

    private mutating func consume(payload: [UInt8]) {
        switch payload[0] & 0x1F {
        case 1...23:
            collect(nalUnit: Data(payload))
        case 24: // STAP-A: [header] ([2-byte size][NAL])*
            var offset = 1
            while offset + 2 <= payload.count {
                let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard size > 0, offset + size <= payload.count else { break }
                collect(nalUnit: Data(payload[offset..<offset + size]))
                offset += size
            }
        case 28: // FU-A: [indicator][S|E|type] fragment
            guard payload.count >= 2 else { return }
            let fuHeader = payload[1]
            if fuHeader & 0x80 != 0 { // start: reconstruct the NAL header byte
                fragmentBuffer = Data([payload[0] & 0xE0 | fuHeader & 0x1F])
            }
            guard fragmentBuffer != nil else { return } // mid-fragment after a drop
            fragmentBuffer?.append(contentsOf: payload[2...])
            if fuHeader & 0x40 != 0, let nalUnit = fragmentBuffer { // end
                collect(nalUnit: nalUnit)
                fragmentBuffer = nil
            }
        default:
            break // FU-B/STAP-B/MTAP are not used by RTP/AVP/TCP senders
        }
    }

    private mutating func collect(nalUnit: Data) {
        switch nalUnit.first.map({ $0 & 0x1F }) {
        case 7: sps = nalUnit
        case 8: pps = nalUnit
        default: pendingNALUnits.append(nalUnit)
        }
    }

    private mutating func finishAccessUnit(timestamp: UInt32) -> H264AccessUnit? {
        defer { pendingNALUnits.removeAll() }
        guard let sps, let pps, !pendingNALUnits.isEmpty else { return nil }

        var avcc = Data()
        var isIDR = false
        for nalUnit in pendingNALUnits {
            withUnsafeBytes(of: UInt32(nalUnit.count).bigEndian) { avcc.append(contentsOf: $0) }
            avcc.append(nalUnit)
            if nalUnit.first.map({ $0 & 0x1F }) == 5 { isIDR = true }
        }
        return H264AccessUnit(sps: sps, pps: pps, data: avcc, isIDR: isIDR, rtpTimestamp: timestamp)
    }
}
