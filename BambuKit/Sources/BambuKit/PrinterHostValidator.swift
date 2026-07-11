import Foundation

/// BambuCam is intentionally a LAN-only client. Requiring a literal RFC 1918
/// IPv4 address prevents a typo or hostile DNS response from receiving a LAN
/// access code.
public enum PrinterHostValidator {
    public static func isAllowed(_ hostname: String) -> Bool {
        let octets = hostname.split(separator: ".", omittingEmptySubsequences: false)
        let values = octets.compactMap { Int($0) }
        guard octets.count == 4,
              values.count == 4,
              values.allSatisfy({ (0...255).contains($0) })
        else { return false }

        let first = values[0]
        let second = values[1]
        return first == 10
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }
}
