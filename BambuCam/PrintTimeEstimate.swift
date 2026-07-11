import Foundation

/// A local presentation of the printer's remaining-time estimate.
///
/// The printer reports whole remaining minutes. The final time is calculated
/// on this Mac so it automatically follows the user's locale and time zone.
struct PrintTimeEstimate: Equatable {
    let remainingMinutes: Int

    init?(remainingMinutes: Int?) {
        guard let remainingMinutes, remainingMinutes >= 0 else { return nil }
        self.remainingMinutes = remainingMinutes
    }

    var remainingText: String {
        guard remainingMinutes > 0 else { return "Under 1m left" }
        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60
        return switch (hours, minutes) {
        case (0, let minutes): "\(minutes)m left"
        case (let hours, 0): "\(hours)h left"
        case (let hours, let minutes): "\(hours)h \(minutes)m left"
        }
    }

    func doneAtText(now: Date = .now) -> String {
        let completion = now.addingTimeInterval(TimeInterval(remainingMinutes * 60))
        return "Done at \(completion.formatted(date: .omitted, time: .shortened))"
    }
}
