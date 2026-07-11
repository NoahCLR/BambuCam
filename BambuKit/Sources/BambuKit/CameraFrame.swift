import Foundation

/// One video frame from a printer camera, in whichever encoding the
/// printer's transport produces. P1/A1 stream complete JPEG stills;
/// X1 streams H.264 access units.
public enum CameraFrame: Sendable, Equatable {
    case jpeg(Data)
    case h264(H264AccessUnit)
}

/// One decodable H.264 access unit. `data` is AVCC: each NAL unit prefixed
/// with its 4-byte big-endian length. SPS/PPS ride along on every unit so a
/// consumer can (re)build its format description whenever they change.
public struct H264AccessUnit: Sendable, Equatable {
    public var sps: Data
    public var pps: Data
    public var data: Data
    /// True when the unit contains an IDR slice (a sync sample: decoding can
    /// start or recover here).
    public var isIDR: Bool
    public var rtpTimestamp: UInt32

    public init(sps: Data, pps: Data, data: Data, isIDR: Bool, rtpTimestamp: UInt32) {
        self.sps = sps
        self.pps = pps
        self.data = data
        self.isIDR = isIDR
        self.rtpTimestamp = rtpTimestamp
    }
}
