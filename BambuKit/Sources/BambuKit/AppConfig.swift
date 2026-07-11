import Foundation

/// Which camera protocol the printer offers, learned by probing during
/// pairing. P1/A1 serve raw JPEG on :6000; X1 serves RTSPS on :322.
public enum CameraTransport: String, Codable, Sendable, Equatable {
    case jpegStream
    case rtsp
}

public struct PrinterConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var serial: String
    /// Whether the printer runs in LAN-only Mode with Developer Mode enabled.
    /// Firmware with authorization control (≥01.08) rejects pause/resume/stop/
    /// speed over LAN otherwise, so the UI disables those controls when false.
    public var developerMode: Bool
    public var cameraTransport: CameraTransport

    public init(id: UUID = UUID(), name: String, hostname: String, serial: String,
                developerMode: Bool = false, cameraTransport: CameraTransport = .jpegStream) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.serial = serial
        self.developerMode = developerMode
        self.cameraTransport = cameraTransport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decode(String.self, forKey: .hostname)
        serial = try container.decode(String.self, forKey: .serial)
        developerMode = try container.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        // Tolerate unknown raw values from newer versions, not just absence.
        cameraTransport = (try? container.decodeIfPresent(CameraTransport.self, forKey: .cameraTransport))
            .flatMap { $0 } ?? .jpegStream
    }
}

public struct NotificationSettings: Codable, Sendable, Equatable {
    public var finished = true
    public var failed = true
    public var connectionLost = true
    public var milestones = true
    public init() {}
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var printers: [PrinterConfig] = []
    public var notifications = NotificationSettings()
    public var launchAtLogin = false
    /// Path of the slicer .app the "Open Slicer" button launches; the user
    /// picks it in Settings (no hardcoded app list to go stale).
    public var slicerPath: String?
    public init() {}

    // Lenient decoding so configs saved before a field existed still load
    // (a failed decode would silently reset the whole config to defaults).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        printers = try container.decodeIfPresent([PrinterConfig].self, forKey: .printers) ?? []
        notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        slicerPath = try container.decodeIfPresent(String.self, forKey: .slicerPath)
    }
}

/// Loads/saves non-secret preferences. Access codes and certificate pins are
/// stored separately in the device-local Keychain.
public struct ConfigStore {
    private let file: URL
    private let secretStore: PrinterSecretStore

    public init(directory: URL, secretStore: PrinterSecretStore = .init()) {
        self.file = directory.appendingPathComponent("config.json")
        self.secretStore = secretStore
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hardenStoragePermissions()
    }

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BambuCam")
        self.init(directory: appSupport)
    }

    public func load() -> AppConfig {
        hardenStoragePermissions()
        if let data = try? Data(contentsOf: file),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            migrateUnsafeAccessCodes(in: data, for: config)
            return config
        }
        return AppConfig()
    }

    public func save(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// A one-time upgrade from BambuCam 1.0's unsafe `accessCode` field. This
    /// does not read or import the discontinued ~/.bambucam legacy config.
    private func migrateUnsafeAccessCodes(in data: Data, for config: AppConfig) {
        guard let legacy = try? JSONDecoder().decode(UnsafeConfig.self, from: data) else { return }
        var migrated = false
        for printer in legacy.printers {
            guard config.printers.contains(where: { $0.id == printer.id }),
                  let accessCode = printer.accessCode,
                  !accessCode.isEmpty
            else { continue }
            do {
                try secretStore.saveAccessCode(accessCode, for: printer.id)
                migrated = true
            } catch {
                // Keep the old file intact if Keychain is unavailable; a later
                // successful load can migrate it without losing the credential.
                return
            }
        }
        if migrated { try? save(config) }
    }

    private func hardenStoragePermissions() {
        let directory = file.deletingLastPathComponent().path
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private struct UnsafeConfig: Decodable {
        var printers: [UnsafePrinter]
    }

    private struct UnsafePrinter: Decodable {
        var id: UUID
        var accessCode: String?
    }
}
