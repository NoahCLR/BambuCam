import Testing
@testable import BambuKit

@Suite struct ReconnectBackoffTests {
    @Test func delaysDoubleAndCapAt30() {
        var b = ReconnectBackoff()
        let delays = (0..<7).map { _ in b.nextDelay() }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8),
                           .seconds(16), .seconds(30), .seconds(30)])
    }
    @Test func resetStartsOver() {
        var b = ReconnectBackoff()
        _ = b.nextDelay(); _ = b.nextDelay()
        b.reset()
        #expect(b.nextDelay() == .seconds(1))
    }
    @Test func staysAt30AfterVeryManyCalls() {
        var b = ReconnectBackoff()
        for _ in 0..<200 { _ = b.nextDelay() }
        #expect(b.nextDelay() == .seconds(30))
    }
}
