import Testing
@testable import BambuKit

@Suite struct PrinterHostValidatorTests {
    @Test(arguments: ["10.0.0.5", "172.16.0.1", "172.31.255.255", "192.168.1.20"])
    func allowsPrivateOrLocalIPv4(_ host: String) {
        #expect(PrinterHostValidator.isAllowed(host))
    }

    @Test(arguments: ["8.8.8.8", "127.0.0.1", "169.254.10.2", "172.32.0.1", "printer.local", "example.com", "192.168.1.999"])
    func rejectsPublicOrNamedHosts(_ host: String) {
        #expect(!PrinterHostValidator.isAllowed(host))
    }
}
