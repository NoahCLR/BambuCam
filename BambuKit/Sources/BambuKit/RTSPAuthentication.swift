import CryptoKit
import Foundation

/// Computes RTSP Authorization header values for Basic and Digest
/// (RFC 2617, MD5, qop=auth) challenges. The printer authenticates as
/// user "bblp" with the LAN access code as password.
public enum RTSPAuthentication {
    /// Picks the strongest supported challenge from a response's
    /// WWW-Authenticate header values: Digest over Basic.
    public static func selectChallenge(from values: [String]) -> String? {
        values.first { scheme(of: $0) == "digest" } ?? values.first { scheme(of: $0) == "basic" }
    }

    /// Returns the Authorization header value answering `challenge`, or nil
    /// when the challenge is unsupported (unknown scheme, non-MD5 algorithm,
    /// or a qop list without "auth").
    public static func authorizationHeader(challenge: String,
                                           method: String,
                                           uri: String,
                                           username: String,
                                           password: String,
                                           cnonce: String,
                                           nonceCount: Int) -> String? {
        switch scheme(of: challenge) {
        case "basic":
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        case "digest":
            return digestHeader(challenge: challenge, method: method, uri: uri,
                                username: username, password: password,
                                cnonce: cnonce, nonceCount: nonceCount)
        default:
            return nil
        }
    }

    private static func digestHeader(challenge: String,
                                     method: String,
                                     uri: String,
                                     username: String,
                                     password: String,
                                     cnonce: String,
                                     nonceCount: Int) -> String? {
        let params = parameters(of: challenge)
        guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
        if let algorithm = params["algorithm"], algorithm.caseInsensitiveCompare("MD5") != .orderedSame {
            return nil
        }
        let qopOffered = params["qop"].map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        let usesQop: Bool
        switch qopOffered {
        case nil: usesQop = false
        case .some(let list) where list.contains("auth"): usesQop = true
        default: return nil // e.g. auth-int only
        }

        let ha1 = md5Hex("\(username):\(realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")
        let nc = String(format: "%08x", nonceCount)
        let response = usesQop
            ? md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
            : md5Hex("\(ha1):\(nonce):\(ha2)")

        var header = "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", "
            + "uri=\"\(uri)\", response=\"\(response)\""
        if usesQop { header += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\"" }
        if let opaque = params["opaque"] { header += ", opaque=\"\(opaque)\"" }
        if params["algorithm"] != nil { header += ", algorithm=MD5" }
        return header
    }

    private static func scheme(of challenge: String) -> String {
        challenge.trimmingCharacters(in: .whitespaces)
            .prefix { !$0.isWhitespace }
            .lowercased()
    }

    /// Parses the challenge's `key="value", key=value` list, honoring quotes.
    private static func parameters(of challenge: String) -> [String: String] {
        let trimmed = challenge.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return [:] }
        let list = trimmed[trimmed.index(after: space)...]

        var items: [String] = []
        var current = ""
        var inQuotes = false
        for character in list {
            if character == "\"" { inQuotes.toggle() }
            if character == "," && !inQuotes {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)

        var params: [String: String] = [:]
        for item in items {
            guard let equals = item.firstIndex(of: "=") else { continue }
            let key = item[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = item[item.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            params[key] = value
        }
        return params
    }

    private static func md5Hex(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
