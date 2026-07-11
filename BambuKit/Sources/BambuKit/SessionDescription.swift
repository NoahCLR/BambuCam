import Foundation

/// The slice of an SDP body (RFC 8866) the camera needs: the video track's
/// control URL, its dynamic RTP payload type, and the out-of-band H.264
/// parameter sets from `sprop-parameter-sets` (RFC 6184 §8.2.1) when the
/// server includes them.
public struct SessionDescription: Sendable, Equatable {
    public var videoControl: String?
    public var videoPayloadType: UInt8?
    public var sps: Data?
    public var pps: Data?

    /// Returns nil when the SDP has no video media section.
    public init?(sdp: String) {
        var inVideoSection = false
        var sawVideoSection = false

        for rawLine in sdp.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                inVideoSection = line.hasPrefix("m=video")
                sawVideoSection = sawVideoSection || inVideoSection
                continue
            }
            guard inVideoSection, line.hasPrefix("a=") else { continue }
            let attribute = line.dropFirst(2)

            if attribute.hasPrefix("control:") {
                videoControl = String(attribute.dropFirst("control:".count))
            } else if attribute.hasPrefix("rtpmap:") {
                // a=rtpmap:96 H264/90000
                let fields = attribute.dropFirst("rtpmap:".count).split(separator: " ")
                if fields.count >= 2, fields[1].uppercased().hasPrefix("H264"),
                   let payloadType = UInt8(fields[0]) {
                    videoPayloadType = payloadType
                }
            } else if attribute.hasPrefix("fmtp:") {
                parseFormatParameters(attribute.dropFirst("fmtp:".count))
            }
        }
        guard sawVideoSection else { return nil }
    }

    /// Resolves the control attribute against the presentation URI:
    /// absolute URLs pass through, "*" (or no control) means the base itself,
    /// anything else is a path relative to the base.
    public func resolvedVideoControl(relativeTo base: String) -> String {
        guard let control = videoControl, control != "*" else { return base }
        if control.contains("://") { return control }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmedBase + "/" + control
    }

    // a=fmtp:96 packetization-mode=1;sprop-parameter-sets=<b64 SPS>,<b64 PPS>
    private mutating func parseFormatParameters(_ attribute: Substring) {
        guard let space = attribute.firstIndex(of: " ") else { return }
        if let expected = videoPayloadType, UInt8(attribute[..<space]) != expected { return }

        for parameter in attribute[attribute.index(after: space)...].split(separator: ";") {
            let parameter = parameter.trimmingCharacters(in: .whitespaces)
            guard parameter.hasPrefix("sprop-parameter-sets=") else { continue }
            let sets = parameter.dropFirst("sprop-parameter-sets=".count)
                .split(separator: ",")
                .compactMap { Self.decodeBase64(String($0)) }
            if sets.count >= 1 { sps = sets[0] }
            if sets.count >= 2 { pps = sets[1] }
        }
    }

    /// sprop values are sometimes emitted without base64 padding.
    private static func decodeBase64(_ value: String) -> Data? {
        var padded = value
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }
}
