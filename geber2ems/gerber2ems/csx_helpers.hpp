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
#include <string>
#include <vector>

#include <CSXCAD/ContinuousStructure.h>
#include <CSXCAD/CSPropDumpBox.h>
#include <CSXCAD/CSPropExcitation.h>
#include <CSXCAD/CSPropLumpedElement.h>
#include <CSXCAD/CSPropMaterial.h>
#include <CSXCAD/CSPropMetal.h>
#include <CSXCAD/CSPropProbeBox.h>
#include <CSXCAD/CSPrimBox.h>
#include <CSXCAD/CSPrimLinPoly.h>
#include <CSXCAD/CSPrimPolygon.h>

namespace gerber2ems {

using Point3 = std::array<double, 3>;

CSPropMetal* addMetal(ContinuousStructure& csx, const std::string& name);
CSPropMaterial* addMaterial(ContinuousStructure& csx, const std::string& name, double epsilon);
CSPropExcitation* addExcitation(ContinuousStructure& csx, const std::string& name, std::int32_t excType,
                                 const Point3& excVal, double delay = 0);
CSPropProbeBox* addProbe(ContinuousStructure& csx, const std::string& name, std::int32_t pType, double weight = 1,
                          std::int32_t normDir = -1);
CSPropLumpedElement* addLumpedElement(ContinuousStructure& csx, const std::string& name, std::int32_t ny, bool caps,
                                       double resistance);
CSPropDumpBox* addDump(ContinuousStructure& csx, const std::string& name, const std::array<std::int32_t, 3>& subSampling);

CSPrimBox* addBox(CSProperties& prop, const Point3& start, const Point3& stop, std::int32_t priority = 0);
CSPrimPolygon* addPolygon(CSProperties& prop, const std::vector<double>& xs, const std::vector<double>& ys,
                           std::int32_t normDir, double elevation, std::int32_t priority = 0);
CSPrimLinPoly* addLinPoly(CSProperties& prop, const std::vector<double>& xs, const std::vector<double>& ys,
                           std::int32_t normDir, double elevation, double length, std::int32_t priority = 0);

} // namespace gerber2ems
