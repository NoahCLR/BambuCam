import Foundation
import Testing
@testable import BambuKit

@Suite struct RTSPAuthenticationTests {
    /// RFC 2617 §3.5 reference vector.
    @Test func digestMatchesRFC2617Vector() throws {
        let challenge = "Digest realm=\"testrealm@host.com\", qop=\"auth,auth-int\", "
            + "nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\", opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""
        let header = try #require(RTSPAuthentication.authorizationHeader(
            challenge: challenge,
            method: "GET",
            uri: "/dir/index.html",
            username: "Mufasa",
            password: "Circle Of Life",
            cnonce: "0a4f113b",
            nonceCount: 1
        ))
        #expect(header.hasPrefix("Digest "))
        #expect(header.contains("response=\"6629fae49393a05397450978507c4ef1\""))
        #expect(header.contains("nc=00000001"))
        #expect(header.contains("qop=auth"))
        #expect(header.contains("opaque=\"5ccc069c403ebaf9f0171e9517f40e41\""))
        #expect(header.contains("uri=\"/dir/index.html\""))
    }

    @Test func basicEncodesCredentials() {
        let header = RTSPAuthentication.authorizationHeader(
            challenge: "Basic realm=\"printer\"",
            method: "DESCRIBE", uri: "rtsps://x/", username: "bblp", password: "12345678",
            cnonce: "unused", nonceCount: 1
        )
        let expected = "Basic " + Data("bblp:12345678".utf8).base64EncodedString()
        #expect(header == expected)
    }

    @Test func digestPreferredWhenBothOffered() {
        let selected = RTSPAuthentication.selectChallenge(from: [
            "Basic realm=\"printer\"",
            "Digest realm=\"printer\", nonce=\"abc\"",
        ])
        #expect(selected?.hasPrefix("Digest") == true)
    }

    @Test func nonceCountIncrements() {
        let challenge = "Digest realm=\"r\", nonce=\"n\", qop=\"auth\""
        let second = RTSPAuthentication.authorizationHeader(
            challenge: challenge, method: "PLAY", uri: "/s", username: "u", password: "p",
            cnonce: "c", nonceCount: 2
        )
        #expect(second?.contains("nc=00000002") == true)
    }

    @Test func unsupportedChallengesReturnNil() {
        // auth-int only
        #expect(RTSPAuthentication.authorizationHeader(
            challenge: "Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\"",
            method: "PLAY", uri: "/s", username: "u", password: "p",
            cnonce: "c", nonceCount: 1) == nil)
        // non-MD5 algorithm
        #expect(RTSPAuthentication.authorizationHeader(
            challenge: "Digest realm=\"r\", nonce=\"n\", algorithm=SHA-256",
            method: "PLAY", uri: "/s", username: "u", password: "p",
            cnonce: "c", nonceCount: 1) == nil)
    }
}
