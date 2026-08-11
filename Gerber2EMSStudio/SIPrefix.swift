import Foundation

/// SI magnitude prefixes accepted on input (and, for the largest few, offered for display) by
/// UnitSuffixValueFormatter. Symbol matching is case-sensitive on purpose -- "M" (mega, 1e6) and
/// "m" (milli, 1e-3) must never be confused, unlike the unit suffix itself, which matches
/// "Hz"/"HZ"/"hz" interchangeably.
enum SIPrefix: CaseIterable {
    case tera, giga, mega, kilo, milli, micro, nano, pico

    var symbol: String {
        switch self {
        case .tera: return "T"
        case .giga: return "G"
        case .mega: return "M"
        case .kilo: return "k"
        case .milli: return "m"
        case .micro: return "µ"
        case .nano: return "n"
        case .pico: return "p"
        }
    }

    var factor: Double {
        switch self {
        case .tera: return 1e12
        case .giga: return 1e9
        case .mega: return 1e6
        case .kilo: return 1e3
        case .milli: return 1e-3
        case .micro: return 1e-6
        case .nano: return 1e-9
        case .pico: return 1e-12
        }
    }

    // "u" for micro, since µ isn't easily typed on most keyboards -- accepted on input alongside
    // the canonical symbol, but never produced on display.
    private var alternateInputSymbols: [String] {
        switch self {
        case .micro: return ["u"]
        default: return []
        }
    }

    /// The prefix a single trailing character matches, if any -- case-sensitive (see type doc).
    static func matching(symbol: String) -> SIPrefix? {
        allCases.first { symbol == $0.symbol || $0.alternateInputSymbols.contains(symbol) }
    }

    /// Largest prefix that keeps `value`'s scaled magnitude >= 1, restricted to kilo/mega/giga/tera
    /// -- this app only ever auto-selects a display prefix for naturally-large values (frequencies
    /// in the kHz-GHz range), never sub-1 units. Returns nil (display in the base unit) below 1000.
    static func bestFit(for value: Double) -> SIPrefix? {
        let magnitude = abs(value)
        return [SIPrefix.tera, .giga, .mega, .kilo].first { magnitude >= $0.factor }
    }
}
