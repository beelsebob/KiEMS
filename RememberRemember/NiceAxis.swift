import Foundation

/// A "nice" (round-number) axis range and tick step covering a data extent -- the standard
/// Heckbert "nice numbers for graph labels" algorithm, so axis bounds/gridlines land on round
/// values (1/2/5 x 10^n) instead of the raw data min/max.
struct NiceAxisRange {
    let min: Double
    let max: Double
    let step: Double

    /// Every tick value from min to max inclusive, in order. Capped defensively -- a malformed
    /// (e.g. non-finite) range could otherwise produce an unbounded loop.
    var ticks: [Double] {
        guard step > 0, step.isFinite, min.isFinite, max.isFinite else { return [min] }
        var result: [Double] = []
        // A viewport may start at an arbitrary value while panning or zooming. Keep that exact
        // viewport boundary, but begin grid lines at the first nice step inside it rather than
        // forcing the viewport itself onto a nice number.
        var value = (min / step).rounded(.up) * step
        if abs(value) < step * 1e-12 { value = 0 }
        let limit = max + step * 0.001
        while value <= limit, result.count < 200 {
            result.append(value)
            value += step
        }
        return result
    }

    /// `targetTicks` is a target, not a guarantee -- the nice-number rounding may land on one more
    /// or fewer gridline than asked for.
    static func range(min dataMin: Double, max dataMax: Double, targetTicks: Int = 5) -> NiceAxisRange {
        var lo = dataMin
        var hi = dataMax
        if !lo.isFinite || !hi.isFinite {
            lo = 0
            hi = 1
        }
        if lo > hi { swap(&lo, &hi) }
        if lo == hi {
            // An absolute ±1 fallback makes a lone tiny measurement (for example a femtoamp-scale
            // probe current) visually collapse onto zero. Expand around a nonzero value relative
            // to its own magnitude; retain the ordinary ±1 default only for an actual zero.
            let padding = lo == 0 ? 1 : abs(lo) * 0.1
            lo -= padding
            hi += padding
        }

        let extent = niceNumber(hi - lo, round: false)
        let step = niceNumber(extent / Double(Swift.max(targetTicks - 1, 1)), round: true)
        let niceMin = (lo / step).rounded(.down) * step
        let niceMax = (hi / step).rounded(.up) * step
        return NiceAxisRange(min: niceMin, max: niceMax, step: step)
    }

    /// Rounds `value` to the nearest "nice" number: 1, 2, 5, or 10 times a power of ten.
    /// `round: false` rounds up instead (used for the overall extent, so the chosen step never
    /// undershoots the data range); `round: true` rounds to the nearest (used for the step itself).
    private static func niceNumber(_ value: Double, round: Bool) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let fraction = value / pow(10, exponent)
        let niceFraction: Double
        if round {
            if fraction < 1.5 { niceFraction = 1 } else if fraction < 3 { niceFraction = 2 } else if fraction < 7 {
                niceFraction = 5
            } else { niceFraction = 10 }
        } else {
            if fraction <= 1 { niceFraction = 1 } else if fraction <= 2 { niceFraction = 2 } else if fraction <= 5 {
                niceFraction = 5
            } else { niceFraction = 10 }
        }
        return niceFraction * pow(10, exponent)
    }
}

/// Compact tick-label text for a nice-axis value -- whole numbers with no decimal point, otherwise
/// 2 decimal places, switching to scientific notation outside a reasonable everyday range.
func formatAxisTick(_ value: Double) -> String {
    if value == 0 { return "0" }
    let magnitude = abs(value)
    if magnitude >= 100000 || magnitude < 0.001 {
        return String(format: "%.1e", value)
    }
    if value.rounded() == value {
        return String(format: "%.0f", value)
    }
    return String(format: "%.2f", value)
}
