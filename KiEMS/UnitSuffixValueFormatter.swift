import Cocoa

/// Displays a value with a fixed unit suffix appended (e.g. "5 s", "2.4 Hz") -- and, when parsing
/// user input back, tolerates a handful of alternate spellings of that same unit (case-insensitive,
/// with or without a space before it). Also accepts a single SI-prefix character adjacent to the
/// unit on input (e.g. "5kHz", "500 ms") -- see SIPrefix -- and, when `autoSelectsSIPrefix` is set,
/// displays large values with the largest-fitting prefix (kilo/mega/giga/tera) instead of the bare
/// unit. Beyond that there's no unit *conversion* here (unlike MillimeterValueFormatter/
/// PhaseValueFormatter) -- these are all single-unit quantities (seconds, hertz, ohms) with no
/// other unit to convert to/from.
final class UnitSuffixValueFormatter: Formatter {
    private let displaySuffix: String
    private let acceptedSuffixes: [String]
    /// Complete, case-sensitive unit spellings which carry their own scale relative to the stored
    /// base unit. This is separate from acceptedSuffixes because case can be semantically
    /// significant: `Gb/s` is gigabits/s, while `GB/s` is gigabytes/s (eight times larger).
    private let scaledSuffixes: [(suffix: String, factor: Double)]
    // When true, string(for:) picks the largest-fitting SI prefix (kilo/mega/giga/tera) for
    // display instead of always showing the base unit -- e.g. 6_000_000_000 displays as "6 GHz"
    // rather than "6,000,000,000 Hz". Parsing an SI-prefixed value back in (see getObjectValue)
    // always works, regardless of this flag -- it only controls what's shown, not what's accepted.
    private let autoSelectsSIPrefix: Bool

    init(displaySuffix: String, acceptedSuffixes: [String],
         scaledSuffixes: [(suffix: String, factor: Double)] = [],
         autoSelectsSIPrefix: Bool = false) {
        self.displaySuffix = displaySuffix
        self.acceptedSuffixes = acceptedSuffixes
        self.scaledSuffixes = scaledSuffixes
        self.autoSelectsSIPrefix = autoSelectsSIPrefix
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        // Accept normal human-entered variants supported by the current locale (grouping
        // separators, leading plus signs, scientific notation, and lenient space/apostrophe
        // grouping) rather than limiting input to Swift's locale-independent Double syntax.
        formatter.isLenient = true
        return formatter
    }()

    /// Parses an entire numeric field with NumberFormatter. `number(from:)` may successfully
    /// return just a numeric prefix (for example, 1 from "1 nonsense"), so use getObjectValue's
    /// consumed range and require it to cover all of the already-trimmed input.
    private static func parseNumber(_ string: String) -> Double? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var parsed: AnyObject?
        var consumedRange = NSRange(location: 0, length: (text as NSString).length)
        do {
            try numberFormatter.getObjectValue(&parsed, for: text, range: &consumedRange)
        } catch {
            return nil
        }
        guard consumedRange.location == 0,
              NSMaxRange(consumedRange) == (text as NSString).length,
              let number = parsed as? NSNumber,
              number.doubleValue.isFinite else {
            return nil
        }
        return number.doubleValue
    }

    override func string(for obj: Any?) -> String? {
        guard let number = obj as? NSNumber else { return nil }
        if autoSelectsSIPrefix, let prefix = SIPrefix.bestFit(for: number.doubleValue) {
            let scaled = NSNumber(value: number.doubleValue / prefix.factor)
            let numberString = Self.numberFormatter.string(from: scaled) ?? scaled.stringValue
            return "\(numberString) \(prefix.symbol)\(displaySuffix)"
        }
        let numberString = Self.numberFormatter.string(from: number) ?? number.stringValue
        return "\(numberString) \(displaySuffix)"
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                  errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try complete scaled aliases before the ordinary suffix/SI-prefix split. Matching is
        // intentionally case-sensitive so bit and byte spellings remain distinct.
        for alias in scaledSuffixes.sorted(by: { $0.suffix.count > $1.suffix.count })
            where trimmed.hasSuffix(alias.suffix) {
            let numberPart = String(trimmed.dropLast(alias.suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Self.parseNumber(numberPart) {
                obj?.pointee = NSNumber(value: value * alias.factor)
                return true
            }
        }
        let upper = trimmed.uppercased()
        for suffix in acceptedSuffixes where upper.hasSuffix(suffix.uppercased()) {
            trimmed = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if let value = Self.parseNumber(trimmed) {
            obj?.pointee = NSNumber(value: value)
            return true
        }
        // No plain parse -- try stripping a single case-sensitive SI-prefix character (e.g. the
        // "k" left over after "5kHz" has its "Hz" suffix stripped above) and rescale.
        if let lastChar = trimmed.last, let prefix = SIPrefix.matching(symbol: String(lastChar)) {
            let withoutPrefix = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",'"))
            if let value = Self.parseNumber(withoutPrefix) {
                obj?.pointee = NSNumber(value: value * prefix.factor)
                return true
            }
        }
        error?.pointee = "\"\(string)\" isn't a valid value" as NSString
        return false
    }
}
