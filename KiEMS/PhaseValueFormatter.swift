import Cocoa

/// Displays/accepts a phase angle -- stores it always in degrees (matching
/// ExcitationConfig::phaseDegrees()'s own naming), but, like MillimeterValueFormatter, remembers
/// (per instance) whichever unit -- degrees or radians -- the user last typed or had displayed, and
/// converts a value entered in the other unit back to degrees before storing it.
final class PhaseValueFormatter: Formatter {
    enum Unit {
        case degrees
        case radians
    }

    var unit: Unit = .degrees

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    // Longest-first within each unit, so e.g. "degrees" doesn't get short-circuited by a shorter
    // spelling before it's ever tried (moot here, since none of these happen to be suffixes of one
    // another, but keeps the intent obvious).
    private static let degreeSuffixes = ["DEGREES", "DEGREE", "DEG.", "DEG", "°"]
    private static let radianSuffixes = ["RADIANS", "RADIAN", "RADS", "RAD.", "RAD"]

    override func string(for obj: Any?) -> String? {
        guard let number = obj as? NSNumber else { return nil }
        let degrees = number.doubleValue
        switch unit {
        case .degrees:
            let numberString = Self.numberFormatter.string(from: NSNumber(value: degrees)) ?? "\(degrees)"
            return "\(numberString)°"
        case .radians:
            let radians = degrees * .pi / 180
            let numberString = Self.numberFormatter.string(from: NSNumber(value: radians)) ?? "\(radians)"
            return "\(numberString) rad"
        }
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                  errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        var trimmed = string.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()

        var parsedUnit: Unit?
        for suffix in Self.degreeSuffixes where upper.hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            parsedUnit = .degrees
            break
        }
        if parsedUnit == nil {
            for suffix in Self.radianSuffixes where upper.hasSuffix(suffix) {
                trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                parsedUnit = .radians
                break
            }
        }

        guard let value = Double(trimmed) else {
            error?.pointee = "\"\(string)\" isn't a valid angle" as NSString
            return false
        }

        // No unit typed -- use whichever this field is currently displaying in, same convention as
        // MillimeterValueFormatter. A unit that *was* typed becomes the new sticky choice, so the
        // field keeps showing values in it from here on.
        let resolvedUnit = parsedUnit ?? unit
        unit = resolvedUnit

        let degrees = resolvedUnit == .degrees ? value : value * 180 / .pi
        obj?.pointee = NSNumber(value: degrees)
        return true
    }
}
