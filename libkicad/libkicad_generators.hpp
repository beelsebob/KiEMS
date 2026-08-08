// See libkicad_generators.cpp: countPadsRaw() calls ensureGeneratorsRegistered() purely to give
// the linker a reason to keep that translation unit's static registration object.
#pragma once

namespace libkicad::detail {

void ensureGeneratorsRegistered();

} // namespace libkicad::detail
