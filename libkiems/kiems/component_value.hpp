// Parses a KiCad footprint's "Value" field text (e.g. "10k", "4k7", "100nF", "4u7", "0R1") into a
// plain SI-unit double -- ohms/henries/farads depending on the component. No library elsewhere in
// kiems does this (confirmed by search); the closest existing thing, KiEMS's
// UnitSuffixValueFormatter.swift, is Swift-only and doesn't handle KiCad's decimal-substitution
// shorthand ("4k7" == 4.7k) anyway.
#pragma once

#include <optional>
#include <string>

namespace kiems {

/// Which physical quantity `raw` is a value for -- governs both the trailing unit word
/// parseComponentValue() strips (see _stripUnitWord(), component_value.cpp) and which SI-prefix
/// marker letter, if any, doubles as a bare 1x/decimal-substitution marker (only Resistance's own
/// 'R' and either Unicode ohm symbol, matching KiCad's "0R1"/"4R7"/"1R" convention --
/// Inductance/Capacitance never allow a bare "H"/"F" the same way).
enum class ComponentUnit {
    Resistance, // ohms
    Inductance, // henries
    Capacitance, // farads
};

/// Returns nullopt if `raw` doesn't parse as a value for `unit` -- callers should log and skip
/// rather than guess.
std::optional<double> parseComponentValue(const std::string& raw, ComponentUnit unit);

/// Parses `raw` and returns the value the solver should use. Negative, NaN, and infinite values are
/// rejected, as are zero-valued capacitors and inductors. A deliberately zero-ohm resistor is a
/// valid physical jumper, though, so it is normalized to a representative 10 mOhm rather than
/// producing the solver's degenerate all-zero R/L/C element. Keep UI validation and lumped-
/// component resolution on this shared normalization so the board view always agrees with
/// what the simulation accepts.
std::optional<double> parseSensibleComponentValue(const std::string& raw, ComponentUnit unit);

} // namespace kiems
