import Foundation
import Network
import Security

/// Builds TLS options that accept exactly one self-signed leaf certificate:
/// the one explicitly trusted during pairing. We intentionally do not fall
/// back to system trust or a hostname-only check.
enum PinnedTLS {
    static func options(certificateDER: Data, queueLabel: String) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
                let received = leaf.map { SecCertificateCopyData($0) as Data }
                complete(received == certificateDER)
            },
            DispatchQueue(label: queueLabel)
        )
        return tlsOptions
    }
}
