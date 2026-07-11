public enum PrintEvent: Sendable, Equatable {
    case finished
    case failed
    case milestone(Int)
}

/// Derives notification-worthy events from consecutive status snapshots.
/// The first snapshot ever seen only seeds state (no stale notifications
/// when launching mid-print).
public struct StatusTransitionDetector {
    private static let milestones = [25, 50, 75]
    private var lastGcodeState: String?
    private var firedMilestones: Set<Int> = []
    private var seenFirstStatus = false

    public init() {}

    public mutating func events(for status: PrinterStatus) -> [PrintEvent] {
        defer { seenFirstStatus = true }
        var events: [PrintEvent] = []

        if let state = status.gcodeState, state != lastGcodeState {
            if seenFirstStatus {
                if state == "FINISH" { events.append(.finished) }
                if state == "FAILED" { events.append(.failed) }
            }
            if state == "RUNNING" {
                if lastGcodeState == "PAUSE" {
                    // Resuming the same job (manual pause / filament runout):
                    // keep already-fired milestones so they don't refire.
                } else if seenFirstStatus && lastGcodeState != nil {
                    // Real job boundary (FINISH/FAILED/IDLE/other -> RUNNING): new job.
                    firedMilestones = []
                } else {
                    // First sight of a running job: milestones already passed don't fire.
                    firedMilestones = passedMilestones(at: status.mcPercent)
                }
            }
            lastGcodeState = state
        }

        if !seenFirstStatus {
            // Seed milestones for a print already in progress at launch.
            firedMilestones = passedMilestones(at: status.mcPercent)
            return events
        }

        if status.gcodeState == "RUNNING", let pct = status.mcPercent {
            for m in Self.milestones where pct >= m && !firedMilestones.contains(m) {
                firedMilestones.insert(m)
                events.append(.milestone(m))
            }
        }
        return events
    }

    private func passedMilestones(at percent: Int?) -> Set<Int> {
        guard let percent else { return [] }
        return Set(Self.milestones.filter { $0 <= percent })
    }
}
