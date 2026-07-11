import Foundation

/// Pulls complete JPEG frames out of the printer's chunked camera byte stream.
/// The camera emits JFIF frames delimited by FFD8FFE0 ... FFD9.
public struct JPEGStreamParser {
    private static let start = Data([0xFF, 0xD8, 0xFF, 0xE0])
    private static let end = Data([0xFF, 0xD9])
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while true {
            guard let startRange = buffer.range(of: Self.start) else {
                // No start marker: keep only a tail that could hold a partial marker.
                if buffer.count > Self.start.count { buffer = buffer.suffix(Self.start.count) }
                break
            }
            guard let endRange = buffer.range(of: Self.end, in: startRange.upperBound..<buffer.endIndex) else {
                // Frame incomplete: drop garbage before the start marker, wait for more data.
                buffer.removeSubrange(buffer.startIndex..<startRange.lowerBound)
                break
            }
            frames.append(Data(buffer[startRange.lowerBound..<endRange.upperBound]))
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
        }
        return frames
    }
}
