#include "CopperTestFixtures.hpp"

#include <algorithm>
#include <cmath>

#include <CSPropExcitation.h>
#include <CSPropLumpedElement.h>
#include <CSPropMaterial.h>
#include <CSPropMetal.h>
#include <CSPropProbeBox.h>
#include <CSPrimBox.h>
#include <CSPrimPolygon.h>
#include <CSRectGrid.h>

#include "FDTD/engine.h"

namespace copper::test {

ContinuousStructure* buildTinyVacuumGrid() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i));
        grid->AddDiscLine(1, static_cast<double>(i));
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 1.0);
    grid->AddDiscLine(2, 2.0);

    auto* exc = new CSPropExcitation(csx->GetParameterSet());
    exc->SetName("test_excite");
    exc->SetExcitType(0);
    exc->SetExcitation(1.0, 2);
    csx->AddProperty(exc);
    auto* excBox = new CSPrimBox(exc->GetParameterSet(), exc);
    excBox->SetCoord(0, 5.0);
    excBox->SetCoord(1, 5.0);
    excBox->SetCoord(2, 5.0);
    excBox->SetCoord(3, 5.0);
    excBox->SetCoord(4, 0.0);
    excBox->SetCoord(5, 1.0);

    return csx;
}

ContinuousStructure* buildPecCavityNoExcitation() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i));
        grid->AddDiscLine(1, static_cast<double>(i));
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 1.0);
    grid->AddDiscLine(2, 2.0);
    return csx;
}

ContinuousStructure* buildPecPaintFixture() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int axis = 0; axis < 3; ++axis) {
        for (int i = 0; i <= 4; ++i) {
            grid->AddDiscLine(axis, static_cast<double>(i));
        }
    }

    auto* metal = new CSPropMetal(csx->GetParameterSet());
    metal->SetName("paint_metal");
    csx->AddProperty(metal);
    auto* metalBox = new CSPrimBox(metal->GetParameterSet(), metal);
    for (int axis = 0; axis < 3; ++axis) {
        metalBox->SetCoord(2 * axis, 0.75);
        metalBox->SetCoord(2 * axis + 1, 3.25);
    }
    metalBox->SetPriority(10);

    auto* metalPolygon = new CSPrimPolygon(metal->GetParameterSet(), metal);
    metalPolygon->ClearCoords();
    metalPolygon->AddCoord(0.5);
    metalPolygon->AddCoord(0.5);
    metalPolygon->AddCoord(3.5);
    metalPolygon->AddCoord(0.5);
    metalPolygon->AddCoord(3.5);
    metalPolygon->AddCoord(3.5);
    metalPolygon->AddCoord(0.5);
    metalPolygon->AddCoord(3.5);
    metalPolygon->SetNormDir(2);
    metalPolygon->SetElevation(4.0);
    metalPolygon->SetPriority(15);

    auto* material = new CSPropMaterial(csx->GetParameterSet());
    material->SetName("paint_material_mask");
    material->SetEpsilon(2.0);
    csx->AddProperty(material);
    auto* materialBox = new CSPrimBox(material->GetParameterSet(), material);
    materialBox->SetCoord(0, 1.75);
    materialBox->SetCoord(1, 3.25);
    materialBox->SetCoord(2, 0.75);
    materialBox->SetCoord(3, 3.25);
    materialBox->SetCoord(4, 0.75);
    materialBox->SetCoord(5, 3.25);
    materialBox->SetPriority(20);

    return csx;
}

ContinuousStructure* buildCpmlCavityNoExcitation() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int axis = 0; axis < 3; ++axis) {
        for (int i = 0; i <= 30; ++i) {
            grid->AddDiscLine(axis, static_cast<double>(i));
        }
    }
    return csx;
}

ContinuousStructure* buildProbeFixture() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i));
        grid->AddDiscLine(1, static_cast<double>(i));
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 1.0);
    grid->AddDiscLine(2, 2.0);

    auto* exc = new CSPropExcitation(csx->GetParameterSet());
    exc->SetName("test_excite");
    exc->SetExcitType(0);
    exc->SetExcitation(1.0, 2);
    csx->AddProperty(exc);
    auto* excBox = new CSPrimBox(exc->GetParameterSet(), exc);
    excBox->SetCoord(0, 5.0);
    excBox->SetCoord(1, 5.0);
    excBox->SetCoord(2, 5.0);
    excBox->SetCoord(3, 5.0);
    excBox->SetCoord(4, 0.0);
    excBox->SetCoord(5, 1.0);

    auto* uProbe = new CSPropProbeBox(csx->GetParameterSet());
    uProbe->SetName("test_ut");
    uProbe->SetProbeType(0);
    uProbe->SetWeighting(-1.0);
    csx->AddProperty(uProbe);
    auto* uBox = new CSPrimBox(uProbe->GetParameterSet(), uProbe);
    uBox->SetCoord(0, 5.0);
    uBox->SetCoord(1, 5.0);
    uBox->SetCoord(2, 5.0);
    uBox->SetCoord(3, 5.0);
    uBox->SetCoord(4, 0.0);
    uBox->SetCoord(5, 1.0);

    auto* iProbe = new CSPropProbeBox(csx->GetParameterSet());
    iProbe->SetName("test_it");
    iProbe->SetProbeType(1);
    iProbe->SetWeighting(1.0);
    iProbe->SetNormalDir(2);
    csx->AddProperty(iProbe);
    auto* iBox = new CSPrimBox(iProbe->GetParameterSet(), iProbe);
    iBox->SetCoord(0, 3.0);
    iBox->SetCoord(1, 7.0);
    iBox->SetCoord(2, 3.0);
    iBox->SetCoord(3, 7.0);
    iBox->SetCoord(4, 0.5);
    iBox->SetCoord(5, 0.5);

    return csx;
}

ContinuousStructure* buildSeriesLumpedRLCFixture(double resistance, double inductance, double capacitance) {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i));
        grid->AddDiscLine(1, static_cast<double>(i));
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 1.0);
    grid->AddDiscLine(2, 2.0);

    auto* lumped = new CSPropLumpedElement(csx->GetParameterSet());
    lumped->SetName("test_lumped");
    lumped->SetDirection(2); // z-axis, matching every other fixture's excitation direction
    lumped->SetLEtype(CSPropLumpedElement::SERIES);
    lumped->SetCaps(true);
    lumped->SetResistance(resistance);
    lumped->SetInductance(inductance);
    lumped->SetCapacity(capacitance);
    csx->AddProperty(lumped);
    auto* box = new CSPrimBox(lumped->GetParameterSet(), lumped);
    box->SetCoord(0, 5.0);
    box->SetCoord(1, 5.0);
    box->SetCoord(2, 5.0);
    box->SetCoord(3, 5.0);
    box->SetCoord(4, 0.0);
    box->SetCoord(5, 1.0);

    return csx;
}

FieldParityResult compareGpuCpuFields(const CopperEngine& gpuEngine, Engine& cpuEngine, const CopperGridDims& dims) {
    FieldParityResult result;
    for (int f = 0; f < 6; ++f) {
        const bool isH = f >= 3;
        const std::vector<float> gpuField = gpuEngine.readField(kAllFields[f]);
        for (std::uint32_t z = 0; z < dims.nz; ++z) {
            for (std::uint32_t y = 0; y < dims.ny; ++y) {
                for (std::uint32_t x = 0; x < dims.nx; ++x) {
                    const float cpuValue = isH ? cpuEngine.GetCurr(kAxisForField[f], x, y, z)
                                                : cpuEngine.GetVolt(kAxisForField[f], x, y, z);
                    const std::uint32_t idx = copperGridIndex(dims, x, y, z);
                    const float gpuValue = gpuField[idx];
                    result.maxAbsDiff = std::max(result.maxAbsDiff, std::fabs(gpuValue - cpuValue));
                    result.maxAbsValue = std::max(result.maxAbsValue, std::fabs(cpuValue));
                    if (cpuValue != 0.0F) {
                        result.anyNonzero = true;
                    }
                }
            }
        }
    }
    return result;
}

} // namespace copper::test
