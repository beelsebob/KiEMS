import Foundation

/// Best-effort guess at whether a net carries power (a supply rail or ground) rather than a signal --
/// decides whether the board setup's power or signal default impedance applies to it. Only ever a
/// default: an explicit net or net-class impedance always wins (see kiems::BoardSetupConfig).
enum PowerNetHeuristic {
    private static let patterns = [
        // Voltage-named rails: +3V3, 5V, -12V, 1V8, +3.3V, VDD_1V2 is caught by the prefix rule below.
        "^[+-]?[0-9]+([.,][0-9]+)?V[0-9]*$",
        // Conventional supply prefixes, optionally qualified (VCC_IO, AVDD, VBUS2, ...).
        "^[AD]?(VCC|VDD|VEE|VSS|VBUS|VBAT|VIN|VSYS|VREF|VPP|VMOT|PWR|POWER)([-_. ]?[A-Z0-9.]*)?$",
        // Ground variants.
        "^[ADP]?(GND|GROUND|GRND)([-_. ]?[A-Z0-9]*)?$",
    ]

    static func isPowerNet(_ name: String) -> Bool {
        // KiCad hierarchical nets are "/sheet/NAME"; only the last component carries the rail name.
        var leaf = name.split(separator: "/").last.map(String.init) ?? name
        leaf = leaf.uppercased()
        if patterns.contains(where: { leaf.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }
        return GroundNetHeuristic.bestGuess(among: [name]) != nil
    }
}
