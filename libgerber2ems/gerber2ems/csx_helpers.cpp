#include "csx_helpers.hpp"

namespace gerber2ems {

CSPropMetal* addMetal(ContinuousStructure& csx, const std::string& name) {
    auto* prop = new CSPropMetal(csx.GetParameterSet());
    prop->SetName(name);
    csx.AddProperty(prop);
    return prop;
}

CSPropMaterial* addMaterial(ContinuousStructure& csx, const std::string& name, double epsilon) {
    auto* prop = new CSPropMaterial(csx.GetParameterSet());
    prop->SetName(name);
    prop->SetEpsilon(epsilon);
    csx.AddProperty(prop);
    return prop;
}

CSPropExcitation* addExcitation(ContinuousStructure& csx, const std::string& name, std::int32_t excType,
                                 const Point3& excVal, double delay) {
    auto* prop = new CSPropExcitation(csx.GetParameterSet());
    prop->SetName(name);
    prop->SetExcitType(excType);
    for (std::int32_t n = 0; n < 3; ++n) {
        prop->SetExcitation(excVal[static_cast<std::size_t>(n)], n);
    }
    if (delay != 0) {
        prop->SetDelay(delay);
    }
    csx.AddProperty(prop);
    return prop;
}

CSPropProbeBox* addProbe(ContinuousStructure& csx, const std::string& name, std::int32_t pType, double weight,
                          std::int32_t normDir) {
    auto* prop = new CSPropProbeBox(csx.GetParameterSet());
    prop->SetName(name);
    prop->SetProbeType(pType);
    prop->SetWeighting(weight);
    if (normDir >= 0) {
        prop->SetNormalDir(static_cast<unsigned int>(normDir));
    }
    csx.AddProperty(prop);
    return prop;
}

CSPropLumpedElement* addLumpedElement(ContinuousStructure& csx, const std::string& name, std::int32_t ny, bool caps,
                                       double resistance) {
    auto* prop = new CSPropLumpedElement(csx.GetParameterSet());
    prop->SetName(name);
    prop->SetDirection(ny);
    prop->SetCaps(caps);
    prop->SetResistance(resistance);
    prop->SetLEtype(CSPropLumpedElement::PARALLEL);
    csx.AddProperty(prop);
    return prop;
}

CSPropDumpBox* addDump(ContinuousStructure& csx, const std::string& name,
                        const std::array<std::int32_t, 3>& subSampling) {
    auto* prop = new CSPropDumpBox(csx.GetParameterSet());
    prop->SetName(name);
    for (std::int32_t ny = 0; ny < 3; ++ny) {
        prop->SetSubSampling(ny, static_cast<unsigned int>(subSampling[static_cast<std::size_t>(ny)]));
    }
    csx.AddProperty(prop);
    return prop;
}

// NOTE: none of these call prop.AddPrimitive() explicitly -- CSPrimitives' own constructor
// already self-registers with its owning property via SetProperty() (confirmed in CSXCAD's
// source, CSPrimitives.cpp), and calling AddPrimitive() again afterward errors with "primitive is
// already owned by this property". The Python wrapper layer doesn't call it either, for the same
// reason.

CSPrimBox* addBox(CSProperties& prop, const Point3& start, const Point3& stop, std::int32_t priority) {
    auto* prim = new CSPrimBox(prop.GetParameterSet(), &prop);
    for (std::int32_t n = 0; n < 3; ++n) {
        prim->SetCoord(2 * n, start[static_cast<std::size_t>(n)]);
        prim->SetCoord(2 * n + 1, stop[static_cast<std::size_t>(n)]);
    }
    prim->SetPriority(priority);
    return prim;
}

CSPrimPolygon* addPolygon(CSProperties& prop, const std::vector<double>& xs, const std::vector<double>& ys,
                           std::int32_t normDir, double elevation, std::int32_t priority) {
    auto* prim = new CSPrimPolygon(prop.GetParameterSet(), &prop);
    prim->ClearCoords();
    for (std::size_t n = 0; n < xs.size(); ++n) {
        prim->AddCoord(xs[n]);
        prim->AddCoord(ys[n]);
    }
    prim->SetNormDir(normDir);
    prim->SetElevation(elevation);
    prim->SetPriority(priority);
    return prim;
}

CSPrimLinPoly* addLinPoly(CSProperties& prop, const std::vector<double>& xs, const std::vector<double>& ys,
                           std::int32_t normDir, double elevation, double length, std::int32_t priority) {
    auto* prim = new CSPrimLinPoly(prop.GetParameterSet(), &prop);
    prim->ClearCoords();
    for (std::size_t n = 0; n < xs.size(); ++n) {
        prim->AddCoord(xs[n]);
        prim->AddCoord(ys[n]);
    }
    prim->SetNormDir(normDir);
    prim->SetElevation(elevation);
    prim->SetLength(length);
    prim->SetPriority(priority);
    return prim;
}

} // namespace gerber2ems
