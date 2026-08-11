import Cocoa

/// A Formatter for NSTextField fields whose underlying model value is always in micrometers --
/// gerber2ems::constants::baseUnit is 1e-6 ("Length units used in the whole script are microns"),
/// and every length-like field in the saved JSON (hull_padding, via_edge_distance, via_spacing,
/// plating thickness, an involved net's length/width, ...) is stored in that same unit, not
/// millimeters. Displays -- and accepts typed input in -- whatever unit the user last typed (mm,
/// mil, in, cm, or µm itself), converting to/from micrometers transparently: reading a field's
/// `.doubleValue` after a successful edit always returns micrometers, matching what every existing
/// read/write call site already assumes. The chosen unit is per-instance state (see `unit`) --
/// give each field its own formatter instance, not a shared one, or unrelated fields would all
/// switch units together whenever any one of them does.
final class MicrometerValueFormatter: Formatter {
    enum Unit: String, CaseIterable {
        case millimeters = "mm"
        case micrometers = "\u{b5}m"
        case mils = "mil"
        case inches = "in"
        case centimeters = "cm"

        var micrometersPerUnit: Double {
            switch self {
            case .millimeters: return 1000.0
            case .micrometers: return 1.0
            case .mils: return 25.4
            case .inches: return 25_400.0
            case .centimeters: return 10_000.0
            }
        }

        /// Recognizes common spellings/abbreviations a user might type, including the inch mark.
        static func parse(suffix raw: String) -> Unit? {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "mm", "millimeter", "millimeters", "millimetre", "millimetres":
                return .millimeters
            case "\u{b5}m", "um", "micrometer", "micrometers", "micrometre", "micrometres", "micron", "microns":
                return .micrometers
            case "mil", "mils", "thou", "thous":
                return .mils
            case "in", "inch", "inches", "\"", "\u{2033}":
                return .inches
            case "cm", "centimeter", "centimeters", "centimetre", "centimetres":
                return .centimeters
            default:
                return nil
            }
        }
    }

    /// The unit currently displayed/accepted for this field -- updates automatically whenever the
    /// user types a different one, and stays put otherwise (a bare number is interpreted in this
    /// unit, not always mm). Defaults to millimeters, not micrometers: mm is the natural unit a
    /// human would type for a PCB-scale dimension, even though the underlying model is µm.
    var unit: Unit = .millimeters

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    override func string(for obj: Any?) -> String? {
        guard let micrometers = (obj as? NSNumber)?.doubleValue else { return nil }
        let displayValue = micrometers / unit.micrometersPerUnit
        guard let numberString = numberFormatter.string(from: NSNumber(value: displayValue)) else { return nil }
        return "\(numberString) \(unit.rawValue)"
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        var text = string.trimmingCharacters(in: .whitespaces)
        var parsedUnit = unit

        // Split off a trailing non-numeric unit suffix, if any (e.g. "5 mil", "0.5in", "12.7\"") --
        // everything after the last digit-or-decimal-point character.
        if let numberEndIndex = text.lastIndex(where: { $0.isNumber || $0 == "." }) {
            let suffixStart = text.index(after: numberEndIndex)
            let suffix = String(text[suffixStart...])
            if !suffix.isEmpty {
                guard let matched = Unit.parse(suffix: suffix) else {
                    error?.pointee = "Unrecognized unit \"\(suffix)\"" as NSString
                    return false
                }
                parsedUnit = matched
                text = String(text[..<suffixStart]).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let number = numberFormatter.number(from: text) else {
            error?.pointee = "Not a valid number" as NSString
            return false
        }

        unit = parsedUnit
        obj?.pointee = NSNumber(value: number.doubleValue * parsedUnit.micrometersPerUnit) as AnyObject
        return true
    }
}
