import Foundation
import Security

/// The two TLS services exposed by a printer. Each service is pinned separately
/// because firmware is free to use different certificates for MQTT and video.
public enum PrinterTLSService: String, Sendable, CaseIterable {
    case mqtt
    case camera
}

public enum PrinterSecretStoreError: Error, Equatable {
    case keychain(OSStatus)
    case invalidUTF8
}

/// Device-local Keychain storage for printer credentials and certificate pins.
///
/// Items are deliberately non-synchronising and `ThisDeviceOnly`: a LAN access
/// code and a trust decision must never be copied to another Mac through iCloud.
public struct PrinterSecretStore: Sendable {
    private let service: String

    public init() {
        service = "com.ncleroy.BambuCam.printer-secrets"
    }

    public init(service: String) {
        self.service = service
    }

    public func accessCode(for printerID: UUID) throws -> String? {
        guard let data = try data(for: account(printerID, "access-code")) else { return nil }
        guard let code = String(data: data, encoding: .utf8) else {
            throw PrinterSecretStoreError.invalidUTF8
        }
        return code
    }

    public func saveAccessCode(_ accessCode: String, for printerID: UUID) throws {
        try save(Data(accessCode.utf8), for: account(printerID, "access-code"))
    }

    public func certificate(for printerID: UUID, service tlsService: PrinterTLSService) throws -> Data? {
        try data(for: account(printerID, "certificate-\(tlsService.rawValue)"))
    }

    public func saveCertificate(_ certificateDER: Data, for printerID: UUID,
                                service tlsService: PrinterTLSService) throws {
        try save(certificateDER, for: account(printerID, "certificate-\(tlsService.rawValue)"))
    }

    public func removeAll(for printerID: UUID) throws {
        for suffix in ["access-code"] + PrinterTLSService.allCases.map({ "certificate-\($0.rawValue)" }) {
            let status = SecItemDelete(query(account: account(printerID, suffix)) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PrinterSecretStoreError.keychain(status)
            }
        }
    }

    private func data(for account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw PrinterSecretStoreError.keychain(status)
        }
    }

    private func save(_ data: Data, for account: String) throws {
        let status = SecItemUpdate(query(account: account) as CFDictionary,
                                   [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw PrinterSecretStoreError.keychain(status)
        }

        var item = query(account: account)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PrinterSecretStoreError.keychain(addStatus)
        }
    }

    private func query(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }

    private func account(_ printerID: UUID, _ suffix: String) -> String {
        "printer.\(printerID.uuidString.lowercased()).\(suffix)"
    }
}
