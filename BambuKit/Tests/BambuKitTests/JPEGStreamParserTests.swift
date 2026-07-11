import Foundation
import Testing
@testable import BambuKit

private let jpegStart = Data([0xFF, 0xD8, 0xFF, 0xE0])
private let jpegEnd = Data([0xFF, 0xD9])
private func frame(_ body: [UInt8]) -> Data { jpegStart + Data(body) + jpegEnd }

@Suite struct JPEGStreamParserTests {
    @Test func singleFrameInOneChunk() {
        var p = JPEGStreamParser()
        let f = frame([0x01, 0x02, 0x03])
        #expect(p.append(f) == [f])
    }

    @Test func frameSplitAcrossChunks() {
        var p = JPEGStreamParser()
        let f = frame([0xAA, 0xBB, 0xCC, 0xDD])
        #expect(p.append(f.prefix(5)) == [])
        #expect(p.append(f.suffix(from: 5)) == [f])
    }

    @Test func twoFramesInOneChunk() {
        var p = JPEGStreamParser()
        let f1 = frame([0x01]), f2 = frame([0x02])
        #expect(p.append(f1 + f2) == [f1, f2])
    }

    @Test func garbageBeforeFrameIsSkipped() {
        var p = JPEGStreamParser()
        let f = frame([0x07])
        #expect(p.append(Data([0x00, 0x11, 0x22]) + f) == [f])
    }

    @Test func bodyContainingEndOfPreviousGarbageNotConfused() {
        // end marker bytes appearing before any start marker must not emit a frame
        var p = JPEGStreamParser()
        #expect(p.append(jpegEnd) == [])
        let f = frame([0x09])
        #expect(p.append(f) == [f])
    }
}
