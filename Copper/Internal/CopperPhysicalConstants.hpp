#pragma once

namespace copper::physical {

// SI values used by the FDTD update equations. These intentionally match the reference openEMS
// constants exactly so parity tests compare algorithms rather than slightly different constants.
inline constexpr double epsilon0 = 8.85418781762e-12;
inline constexpr double mu0 = 1.256637062e-6;
inline constexpr double impedance0 = 376.730313461;
inline constexpr double pi = 3.141592653589793238462643383279;

} // namespace copper::physical
