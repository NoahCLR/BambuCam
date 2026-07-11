import AppKit
import BambuKit
import CoreImage
import CoreMedia
import VideoToolbox

/// Decodes H.264 access units into `NSImage`s for the SwiftUI camera views.
/// Decoding is synchronous — without the asynchronous-decompression flag,
/// VideoToolbox runs the output handler on the calling thread before
/// `DecodeFrame` returns — so the whole decoder stays on the main actor and
/// no CVPixelBuffer ever crosses an isolation boundary.
@MainActor
final class H264FrameDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: (sps: Data, pps: Data)?
    /// Decoding can only start or recover at an IDR; frames before the next
    /// one after an error would render as garbage.
    private var awaitingIDR = true
    private let ciContext = CIContext()

    func image(for accessUnit: H264AccessUnit) -> NSImage? {
        if parameterSets?.sps != accessUnit.sps || parameterSets?.pps != accessUnit.pps {
            rebuildSession(sps: accessUnit.sps, pps: accessUnit.pps)
        }
        guard let session, let format else { return nil }
        if awaitingIDR {
            guard accessUnit.isIDR else { return nil }
            awaitingIDR = false
        }
        guard let sample = Self.makeSampleBuffer(accessUnit: accessUnit, format: format) else { return nil }

        let output = DecodedFrameBox()
        let status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sample,
                                                       flags: [],
                                                       infoFlagsOut: nil) { _, _, imageBuffer, _, _ in
            output.imageBuffer = imageBuffer
        }
        guard status == noErr, let decoded = output.imageBuffer else {
            awaitingIDR = true
            return nil
        }

        let ciImage = CIImage(cvImageBuffer: decoded)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func rebuildSession(sps: Data, pps: Data) {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = (sps, pps)
        awaitingIDR = true

        var description: CMVideoFormatDescription?
        let created = sps.withUnsafeBytes { (spsBytes: UnsafeRawBufferPointer) in
            pps.withUnsafeBytes { (ppsBytes: UnsafeRawBufferPointer) in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                                ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                // 4-byte NAL length prefixes, matching the AVCC access units.
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard created == noErr, let description else { return }

        var decompressionSession: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                           formatDescription: description,
                                           decoderSpecification: nil,
                                           imageBufferAttributes: nil,
                                           outputCallback: nil,
                                           decompressionSessionOut: &decompressionSession) == noErr,
              let decompressionSession
        else { return }
        format = description
        session = decompressionSession
    }

    /// Synchronous decoding runs the (@Sendable-typed) output handler on the
    /// calling thread before DecodeFrame returns, so this is never actually
    /// touched concurrently.
    private final class DecodedFrameBox: @unchecked Sendable {
        var imageBuffer: CVImageBuffer?
    }

    private static func makeSampleBuffer(accessUnit: H264AccessUnit,
                                         format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let data = accessUnit.data
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: data.count,
                                                 flags: 0,
                                                 blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer
        else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(accessUnit.rtpTimestamp), timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: blockBuffer,
                                        formatDescription: format,
                                        sampleCount: 1,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr
        else { return nil }
        return sampleBuffer
    }
}
