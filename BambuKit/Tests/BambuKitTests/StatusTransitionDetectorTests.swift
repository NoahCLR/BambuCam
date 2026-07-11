import Testing
@testable import BambuKit

private func status(state: String? = nil, percent: Int? = nil) -> PrinterStatus {
    var s = PrinterStatus()
    s.gcodeState = state
    s.mcPercent = percent
    return s
}

@Suite struct StatusTransitionDetectorTests {
    @Test func finishFiresOnceOnTransition() {
        var d = StatusTransitionDetector()
        _ = d.events(for: status(state: "RUNNING", percent: 99))
        #expect(d.events(for: status(state: "FINISH", percent: 100)) == [.finished])
        #expect(d.events(for: status(state: "FINISH", percent: 100)) == [])
    }

    @Test func failedFiresOnTransition() {
        var d = StatusTransitionDetector()
        _ = d.events(for: status(state: "RUNNING", percent: 50))
        #expect(d.events(for: status(state: "FAILED", percent: 50)) == [.failed])
    }

    @Test func firstEverStatusFiresNothing() {
        // App launched mid-print or mid-finished-state: no stale notifications.
        var d = StatusTransitionDetector()
        #expect(d.events(for: status(state: "FINISH", percent: 100)) == [])
    }

    @Test func milestonesFireOnceEachWhileRunning() {
        var d = StatusTransitionDetector()
        _ = d.events(for: status(state: "RUNNING", percent: 1))
        #expect(d.events(for: status(state: "RUNNING", percent: 25)) == [.milestone(25)])
        #expect(d.events(for: status(state: "RUNNING", percent: 30)) == [])
        #expect(d.events(for: status(state: "RUNNING", percent: 80)) == [.milestone(50), .milestone(75)])
    }

    @Test func launchingMidPrintDoesNotBackfillMilestones() {
        var d = StatusTransitionDetector()
        #expect(d.events(for: status(state: "RUNNING", percent: 60)) == [])
        #expect(d.events(for: status(state: "RUNNING", percent: 75)) == [.milestone(75)])
    }

    @Test func newJobResetsMilestones() {
        var d = StatusTransitionDetector()
        _ = d.events(for: status(state: "RUNNING", percent: 1))
        _ = d.events(for: status(state: "RUNNING", percent: 80))
        _ = d.events(for: status(state: "FINISH", percent: 100))
        _ = d.events(for: status(state: "RUNNING", percent: 2))   // new job starts
        #expect(d.events(for: status(state: "RUNNING", percent: 26)) == [.milestone(25)])
    }

    @Test func pauseResumeDoesNotRefireMilestones() {
        var d = StatusTransitionDetector()
        _ = d.events(for: status(state: "RUNNING", percent: 1))
        #expect(d.events(for: status(state: "RUNNING", percent: 30)) == [.milestone(25)])
        _ = d.events(for: status(state: "PAUSE", percent: 30))
        #expect(d.events(for: status(state: "RUNNING", percent: 31)) == [])
        #expect(d.events(for: status(state: "RUNNING", percent: 55)) == [.milestone(50)])
    }

    @Test func finishThenRunningIsNewJob() {
        var d = StatusTransitionDetector()
        _ = d.events(for: status(state: "RUNNING", percent: 1))
        _ = d.events(for: status(state: "RUNNING", percent: 80))
        _ = d.events(for: status(state: "FINISH", percent: 100))
        _ = d.events(for: status(state: "RUNNING", percent: 2))
        #expect(d.events(for: status(state: "RUNNING", percent: 26)) == [.milestone(25)])
    }
}
