import Foundation
import Testing
@testable import BambuKit

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BambuKitTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func testSecretStore() -> PrinterSecretStore {
    PrinterSecretStore(service: "com.ncleroy.BambuCam.tests.\(UUID().uuidString)")
}

@Suite struct ConfigStoreTests {
    @Test func loadWithNoFileReturnsDefaults() throws {
        let store = ConfigStore(directory: try tempDir(), secretStore: testSecretStore())
        let config = store.load()
        #expect(config.printers.isEmpty)
        #expect(config.notifications == NotificationSettings())
        #expect(config.launchAtLogin == false)
    }

    @Test func saveThenLoadRoundTripsWithoutSecrets() throws {
        let directory = try tempDir()
        let store = ConfigStore(directory: directory, secretStore: testSecretStore())
        var config = AppConfig()
        config.printers = [PrinterConfig(id: UUID(), name: "P1S", hostname: "10.0.0.5", serial: "SER123")]
        config.notifications.milestones = false
        config.launchAtLogin = true
        try store.save(config)

        #expect(store.load() == config)
        let persisted = try String(contentsOf: directory.appendingPathComponent("config.json"), encoding: .utf8)
        #expect(!persisted.contains("accessCode"))
    }

    @Test func migratesPreviousPlaintextAccessCodeToKeychainThenRemovesItFromDisk() throws {
        let directory = try tempDir()
        let printerID = UUID()
        let accessCode = "migration-test-code"
        let json = """
        {"printers":[{"id":"\(printerID.uuidString)","name":"P1S","hostname":"10.0.0.5","accessCode":"\(accessCode)","serial":"SER123"}]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))

        let secrets = testSecretStore()
        defer { try? secrets.removeAll(for: printerID) }
        let store = ConfigStore(directory: directory, secretStore: secrets)
        let config = store.load()

        #expect(config.printers.first?.id == printerID)
        #expect(try secrets.accessCode(for: printerID) == accessCode)
        let persisted = try String(contentsOf: directory.appendingPathComponent("config.json"), encoding: .utf8)
        #expect(!persisted.contains("accessCode"))
    }

    @Test func configPermissionsAreOwnerOnly() throws {
        let directory = try tempDir()
        let store = ConfigStore(directory: directory, secretStore: testSecretStore())
        try store.save(AppConfig())

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("config.json").path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func developerModeDefaultsToFalseWhenAbsent() throws {
        let directory = try tempDir()
        let json = """
        {"printers":[{"id":"\(UUID().uuidString)","name":"P1S","hostname":"10.0.0.5","serial":"SER123"}]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))

        let config = ConfigStore(directory: directory, secretStore: testSecretStore()).load()
        #expect(config.printers.first?.developerMode == false)
    }

    @Test func cameraTransportDefaultsToJPEGWhenAbsent() throws {
        let directory = try tempDir()
        let json = """
        {"printers":[{"id":"\(UUID().uuidString)","name":"P1S","hostname":"10.0.0.5","serial":"SER123"}]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))

        let config = ConfigStore(directory: directory, secretStore: testSecretStore()).load()
        #expect(config.printers.first?.cameraTransport == .jpegStream)
    }

    @Test func cameraTransportRoundTrips() throws {
        let store = ConfigStore(directory: try tempDir(), secretStore: testSecretStore())
        var config = AppConfig()
        config.printers = [PrinterConfig(name: "X1C", hostname: "10.0.0.6", serial: "SER456",
                                         cameraTransport: .rtsp)]
        try store.save(config)
        #expect(store.load().printers.first?.cameraTransport == .rtsp)
    }

    @Test func unknownCameraTransportFallsBackWithoutResettingConfig() throws {
        let directory = try tempDir()
        let json = """
        {"printers":[{"id":"\(UUID().uuidString)","name":"H2D","hostname":"10.0.0.7","serial":"SER789","cameraTransport":"quantumEntanglement"}]}
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))

        let config = ConfigStore(directory: directory, secretStore: testSecretStore()).load()
        #expect(config.printers.first?.name == "H2D")
        #expect(config.printers.first?.cameraTransport == .jpegStream)
    }

    @Test func slicerPathRoundTrips() throws {
        let store = ConfigStore(directory: try tempDir(), secretStore: testSecretStore())
        var config = AppConfig()
        config.slicerPath = "/Applications/OrcaSlicer.app"
        try store.save(config)
        #expect(store.load().slicerPath == "/Applications/OrcaSlicer.app")
    }

    @Test func corruptFileFallsBackToDefaults() throws {
        let directory = try tempDir()
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("config.json"))
        let store = ConfigStore(directory: directory, secretStore: testSecretStore())
        #expect(store.load() == AppConfig())
    }
}
