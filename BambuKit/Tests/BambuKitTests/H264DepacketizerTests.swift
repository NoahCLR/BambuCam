import Foundation
import Testing
@testable import BambuKit

private let sps = Data([0x67, 0x42, 0x80, 0x1E])
private let pps = Data([0x68, 0xCE, 0x06, 0xE2])

/// A minimal RTP packet wrapping `payload` (RFC 6184 payloads under test).
private func rtp(seq: UInt16, timestamp: UInt32, marker: Bool, payload: [UInt8]) -> RTPPacket {
    var header = Data([0x80, marker ? 0xE0 : 0x60])
    header += Data([UInt8(seq >> 8), UInt8(seq & 0xFF)])
    withUnsafeBytes(of: timestamp.bigEndian) { header.append(contentsOf: $0) }
    header += Data([0, 0, 0, 1]) // ssrc
    return RTPPacket(data: header + Data(payload))!
}

private func avcc(_ nalUnits: [UInt8]...) -> Data {
    var data = Data()
    for nalUnit in nalUnits {
        withUnsafeBytes(of: UInt32(nalUnit.count).bigEndian) { data.append(contentsOf: $0) }
        data += Data(nalUnit)
    }
    return data
}

@Suite struct H264DepacketizerTests {
    @Test func singleNALEmitsOnMarker() {
        var depacketizer = H264Depacketizer(sps: sps, pps: pps)
        let nalUnit: [UInt8] = [0x41, 0x9A, 0x00, 0x01] // non-IDR slice (type 1)

        #expect(depacketizer.append(rtp(seq: 1, timestamp: 100, marker: false, payload: nalUnit)).isEmpty)
        let units = depacketizer.append(rtp(seq: 2, timestamp: 100, marker: true, payload: [0x41, 0x9B]))
        #expect(units.count == 1)
        #expect(units[0].data == avcc(nalUnit, [0x41, 0x9B]))
        #expect(!units[0].isIDR)
        #expect(units[0].sps == sps)
        #expect(units[0].rtpTimestamp == 100)
    }

    @Test func fuaIDRReassemblesAcrossThreeFragments() {
        var depacketizer = H264Depacketizer(sps: sps, pps: pps)
        let body: [UInt8] = Array(1...12)
        // Original NAL: header 0x65 (nal_ref_idc 3, type 5 = IDR) + body.
        // FU indicator keeps the header's upper bits with type 28.
        let indicator: UInt8 = 0x65 & 0xE0 | 28

        #expect(depacketizer.append(rtp(seq: 1, timestamp: 90_000, marker: false,
                                        payload: [indicator, 0x85] + body[0..<4])).isEmpty)
        #expect(depacketizer.append(rtp(seq: 2, timestamp: 90_000, marker: false,
                                        payload: [indicator, 0x05] + body[4..<8])).isEmpty)
        let units = depacketizer.append(rtp(seq: 3, timestamp: 90_000, marker: true,
                                            payload: [indicator, 0x45] + body[8..<12]))
        #expect(units.count == 1)
        #expect(units[0].data == avcc([0x65] + body))
        #expect(units[0].isIDR)
    }

    @Test func stapAUpdatesParameterSets() {
        var depacketizer = H264Depacketizer() // no seed: SPS/PPS must come in-band
        var stapA: [UInt8] = [24]
        for parameterSet in [sps, pps] {
            stapA += [UInt8(parameterSet.count >> 8), UInt8(parameterSet.count & 0xFF)]
            stapA += [UInt8](parameterSet)
        }
        #expect(depacketizer.append(rtp(seq: 1, timestamp: 50, marker: false, payload: stapA)).isEmpty)

        let units = depacketizer.append(rtp(seq: 2, timestamp: 50, marker: true, payload: [0x65, 0x01]))
        #expect(units.count == 1)
        #expect(units[0].sps == sps)
        #expect(units[0].pps == pps)
        #expect(units[0].data == avcc([0x65, 0x01])) // parameter sets excluded from the unit
    }

    @Test func timestampChangeEmitsWithoutMarker() {
        var depacketizer = H264Depacketizer(sps: sps, pps: pps)
        #expect(depacketizer.append(rtp(seq: 1, timestamp: 100, marker: false, payload: [0x41, 0x01])).isEmpty)

        // The next timestamp both flushes the previous unit and, with the
        // marker set, completes its own.
        let units = depacketizer.append(rtp(seq: 2, timestamp: 200, marker: true, payload: [0x41, 0x02]))
        #expect(units.count == 2)
        #expect(units[0].rtpTimestamp == 100)
        #expect(units[0].data == avcc([0x41, 0x01]))
        #expect(units[1].rtpTimestamp == 200)
        #expect(units[1].data == avcc([0x41, 0x02]))
    }

    @Test func sequenceGapDropsUnitAndRecovers() {
        var depacketizer = H264Depacketizer(sps: sps, pps: pps)
        let indicator: UInt8 = 0x65 & 0xE0 | 28

        // Fragment start at seq 10, middle at seq 11 lost, end arrives at seq 12.
        #expect(depacketizer.append(rtp(seq: 10, timestamp: 100, marker: false,
                                        payload: [indicator, 0x85, 0x01])).isEmpty)
        #expect(depacketizer.append(rtp(seq: 12, timestamp: 100, marker: true,
                                        payload: [indicator, 0x45, 0x03])).isEmpty)

        // The next intact unit decodes normally.
        let units = depacketizer.append(rtp(seq: 13, timestamp: 200, marker: true, payload: [0x41, 0x07]))
        #expect(units.count == 1)
        #expect(units[0].data == avcc([0x41, 0x07]))
    }

    @Test func noAccessUnitWithoutParameterSets() {
        var depacketizer = H264Depacketizer() // never receives SPS/PPS
        let units = depacketizer.append(rtp(seq: 1, timestamp: 100, marker: true, payload: [0x65, 0x01]))
        #expect(units.isEmpty)
    }
}
