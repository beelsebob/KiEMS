// Parses a KiCad footprint's "Value" field text (e.g. "10k", "4k7", "100nF", "4u7", "0R1") into a
// plain SI-unit double -- ohms/henries/farads depending on the component. No library elsewhere in
// gerber2ems does this (confirmed by search); the closest existing thing, Gerber2EMSStudio's
// UnitSuffixValueFormatter.swift, is Swift-only and doesn't handle KiCad's decimal-substitution
// shorthand ("4k7" == 4.7k) anyway.
#pragma once

#include <optional>
#include <string>

namespace gerber2ems {

/// `unitLetter` is 'R' (resistor, ohms -- 'R'/'\xCE\xA9' both accepted as the bare-multiplier/
/// decimal-substitution marker), 'H' (inductor, henries), or 'F' (capacitor, farads). Returns
/// nullopt if `raw` doesn't parse as a value for that unit -- callers should log and skip rather
/// than guess.
std::optional<double> parseComponentValue(const std::string& raw, char unitLetter);

} // namespace gerber2ems
