import Foundation

/// Maps a reference designator (e.g. "C89", "TP3") to a display category name, following the class
/// designation letters in IEEE 315-1975 (ANSI Y32.2) -- extended with a handful of designators
/// (e.g. "TP", "FB") that aren't part of the original standard but are near-universal in practice,
/// KiCad included. Used to group the Footprint/Pin source list under headings like "Capacitors" and
/// "Resistors" instead of a single flat list of every component on the board.
enum ComponentCategory {
    static let fallback = "Other"

    /// Keyed by the designator's letter prefix (everything before the first digit), longest prefix
    /// first -- e.g. "TP3"'s letter prefix is "TP", which needs to be checked (and matched) before
    /// the single-letter "T" (Transformers) entry, or it would wrongly match that instead.
    private static let designators: [(prefix: String, category: String)] = [
        // Two-or-more-letter designators, before any single-letter one they could be confused with.
        ("TP", "Test Points"),
        ("FB", "Ferrite Beads"),
        ("SW", "Switches"),
        ("LS", "Speakers"),
        ("DS", "Displays"),
        ("BT", "Batteries"),
        ("RT", "Thermistors"),
        ("RV", "Varistors"),
        ("RN", "Resistor Networks"),
        ("FL", "Filters"),
        ("MP", "Mechanical Parts"),
        ("MK", "Microphones"),
        ("XF", "Fuse Holders"),
        ("XV", "Tube Sockets"),
        ("VR", "Voltage Regulators"),
        ("CR", "Diodes"),
        ("CN", "Connectors"),
        ("CB", "Circuit Breakers"),
        ("AT", "Attenuators"),
        ("HY", "Hybrids"),
        ("TC", "Thermocouples"),
        ("TB", "Terminal Boards"),
        ("PS", "Power Supplies"),
        ("DL", "Delay Lines"),
        ("XTAL", "Crystals"),

        // Single-letter designators.
        ("A", "Assemblies"),
        ("B", "Batteries"),
        ("C", "Capacitors"),
        ("D", "Diodes"),
        ("E", "Miscellaneous"),
        ("F", "Fuses"),
        ("G", "Oscillators"),
        ("H", "Hardware"),
        ("J", "Connectors"),
        ("K", "Relays"),
        ("L", "Inductors"),
        ("M", "Motors"),
        ("P", "Connectors"),
        ("Q", "Transistors"),
        ("R", "Resistors"),
        ("S", "Switches"),
        ("T", "Transformers"),
        ("U", "Integrated Circuits"),
        ("W", "Wires"),
        ("X", "Sockets"),
        ("Y", "Crystals"),
        ("Z", "Networks"),
    ]

    /// The letter-prefix designators list above, longest-first already, but re-sorted defensively by
    /// descending prefix length in case an entry's ever added out of order -- correctness here
    /// shouldn't depend on remembering to insert new rows in the right spot.
    private static let orderedDesignators = designators.sorted { $0.prefix.count > $1.prefix.count }

    static func category(forReference reference: String) -> String {
        let letterPrefix = String(reference.prefix { $0.isLetter }).uppercased()
        guard !letterPrefix.isEmpty else { return fallback }
        for (designatorPrefix, category) in orderedDesignators where letterPrefix.hasPrefix(designatorPrefix) {
            return category
        }
        return fallback
    }
}
