import Foundation

/// Best-effort heuristic for picking whichever name in a list looks most like a board's single
/// global ground -- shared between DocumentWindowController (guessing a ground net when a new
/// simulation is created) and SimulationPropertiesViewController (guessing again when the user
/// switches between Net/Net Class mode with nothing already remembered).
enum GroundNetHeuristic {
    /// Prefers, in order: an exact match to a well-known ground name; a qualified variant of one --
    /// a letter/number suffix (GND1, GND_A) or a compound word built around it (PowerGround,
    /// PwrGnd); then, as a last resort, any name merely containing "gnd"/"ground" somewhere. Within
    /// each tier, shorter names win -- a short generic name like "GND" is more likely the actual
    /// global ground than a longer, more qualified one like "GND_ANALOG_ISOLATED", which is more
    /// likely a distinct sub-plane. Returns nil rather than guessing if nothing plausible is found.
    /// Works equally for net names and net *class* names -- the same naming conventions apply to both.
    static func bestGuess(among names: [String]) -> String? {
        let wellKnownNames = ["GND", "GROUND", "VSS", "GRND"]

        for candidate in wellKnownNames {
            if let match = names.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return match
            }
        }

        let wellKnownAlternation = wellKnownNames.joined(separator: "|")
        let qualifiedPatterns = [
            "^(?:\(wellKnownAlternation))[-_. ]?[A-Za-z0-9]*$",
            "^[A-Za-z0-9]*[-_. ]?(?:\(wellKnownAlternation))$",
        ]
        let qualifiedMatches = names.filter { name in
            qualifiedPatterns.contains { name.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        if let best = qualifiedMatches.min(by: { $0.count < $1.count }) {
            return best
        }

        let looseMatches = names.filter {
            $0.range(of: "gnd", options: .caseInsensitive) != nil
                || $0.range(of: "ground", options: .caseInsensitive) != nil
        }
        return looseMatches.min(by: { $0.count < $1.count })
    }
}
