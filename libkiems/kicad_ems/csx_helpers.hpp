// Small convenience wrappers around CSXCAD's raw C++ property/primitive API.
//
// Calls like `csx.AddMetal("Plane")` or `metal.AddBox(start, stop, priority=1)` used throughout
// simulation.py are CSXCAD's own Python convenience layer (CSXCAD/python/CSXCAD/CSXCAD.pyx and
// CSProperties.pyx), not part of the compiled C++ library -- the library itself only exposes the
// lower-level CSPropMetal/CSPrimBox/etc. classes plus ContinuousStructure::AddProperty /
// CSProperties::AddPrimitive. This header reimplements just the slice of that convenience layer
// simulation.cpp needs, matching the Python wrappers' exact call sequences (verified against
// CSXCAD's own .pyx sources) so call sites there read close to the original Python.
#pragma once

#include <array>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include <CSXCAD/ContinuousStructure.h>
#include <CSXCAD/CSPropConductingSheet.h>
#include <CSXCAD/CSPropDumpBox.h>
#include <CSXCAD/CSPropExcitation.h>
#include <CSXCAD/CSPropLumpedElement.h>
#include <CSXCAD/CSPropMaterial.h>
#include <CSXCAD/CSPropMetal.h>
#include <CSXCAD/CSPropProbeBox.h>
#include <CSXCAD/CSPrimBox.h>
#include <CSXCAD/CSPrimLinPoly.h>
#include <CSXCAD/CSPrimPolygon.h>

namespace kicad_ems {

using Point3 = std::array<double, 3>;

CSPropMetal* addMetal(ContinuousStructure& csx, const std::string& name);
/// A thin conductive sheet with finite conductivity (S/m) and thickness (simulation units, same
/// convention as every other length this codebase passes to CSXCAD) -- openEMS's own surface-
/// impedance model for a real metal layer, letting a trace's own skin-effect/ohmic loss show up
/// without needing to mesh the skin depth itself (a few microns, far finer than this pipeline's
/// otherwise-copper-driven grid). A CSPropMetal subclass, so every existing CSPropMetal-typed use
/// (priority ordering, etc.) still applies.
CSPropConductingSheet* addConductingSheet(ContinuousStructure& csx, const std::string& name, double conductivity,
                                            double thickness);
/// `kappa` is the material's electric conductivity in S/m (dielectric loss) -- left at its default
/// of 0 (a lossless dielectric) for callers that don't have a loss figure for this material.
CSPropMaterial* addMaterial(ContinuousStructure& csx, const std::string& name, double epsilon, double kappa = 0);
CSPropExcitation* addExcitation(ContinuousStructure& csx, const std::string& name, std::int32_t excType,
                                 const Point3& excVal, double delay = 0);
CSPropProbeBox* addProbe(ContinuousStructure& csx, const std::string& name, std::int32_t pType, double weight = 1,
                          std::int32_t normDir = -1);
/// `type`/`inductance`/`capacitance` default to a plain PARALLEL resistor (this helper's original,
/// still-used shape -- see ports.cpp's port-resistor call sites) -- pass `SERIES` plus real
/// inductance/capacitance for an auto-discovered lumped R/L/C component (see
/// Simulation::addLumpedComponents()). NaN (the CSPropLumpedElement/Operator_Ext_LumpedRLC default
/// for an unset value) means "not physically present", not "present, value zero" -- see
/// operator_ext_lumpedRLC.cpp's own doc comment on that distinction.
CSPropLumpedElement* addLumpedElement(ContinuousStructure& csx, const std::string& name, std::int32_t ny, bool caps,
                                       double resistance, CSPropLumpedElement::LEtype type = CSPropLumpedElement::PARALLEL,
                                       double inductance = std::numeric_limits<double>::quiet_NaN(),
                                       double capacitance = std::numeric_limits<double>::quiet_NaN());
CSPropDumpBox* addDump(ContinuousStructure& csx, const std::string& name, const std::array<std::int32_t, 3>& subSampling);

CSPrimBox* addBox(CSProperties& prop, const Point3& start, const Point3& stop, std::int32_t priority = 0);
CSPrimPolygon* addPolygon(CSProperties& prop, const std::vector<double>& xs, const std::vector<double>& ys,
                           std::int32_t normDir, double elevation, std::int32_t priority = 0);
CSPrimLinPoly* addLinPoly(CSProperties& prop, const std::vector<double>& xs, const std::vector<double>& ys,
                           std::int32_t normDir, double elevation, double length, std::int32_t priority = 0);

} // namespace kicad_ems
