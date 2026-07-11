import Foundation
import Testing
@testable import BambuKit

@Suite struct PrinterClientTests {
    /// A failed connect must throw cleanly and shut down its event loop. This
    /// catches leaked handshake promises in the direct pinned MQTT transport.
    @Test func failedConnectThrowsInsteadOfTrapping() async {
        // Port 1 on localhost: nothing listens there, connect is refused immediately.
        let client = PrinterClient(hostname: "127.0.0.1", accessCode: "x", serial: "x",
                                   certificateDER: Data(), port: 1)
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }
}
