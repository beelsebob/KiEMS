import Foundation

/// Formats an estimated seconds-remaining duration the same rough way Finder phrases its own
/// copy-progress estimates ("About 5 seconds remaining", "About 2 minutes remaining", ...) -- built
/// on DateComponentsFormatter rather than hand-rolled thresholds, so the wording/rounding matches
/// Apple's own convention for this instead of an approximation of it.
enum TimeRemainingFormatter {
    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 1
        formatter.collapsesLargestUnit = true
        return formatter
    }()

    /// `secondsRemaining` nil (not enough progress yet to extrapolate a total from elapsed time)
    /// reads as still-figuring-it-out, matching Finder's own "Calculating time remaining…" phase.
    static func string(secondsRemaining: Double?) -> String {
        guard let secondsRemaining, secondsRemaining.isFinite, secondsRemaining >= 0,
              // Clamped to at least 1s -- DateComponentsFormatter would otherwise render a
              // near-zero estimate as the oddly-precise "0 seconds remaining".
              let formatted = formatter.string(from: max(secondsRemaining, 1)) else {
            return "Calculating time remaining…"
        }
        return "About \(formatted) remaining"
    }
}
