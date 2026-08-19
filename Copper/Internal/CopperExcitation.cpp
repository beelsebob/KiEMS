#include "CopperExcitation.hpp"

#include "CopperOpenEMSAccess.hpp"

namespace copper {

namespace {

Operator_Ext_Excitation* findExcitationExtension(Operator& op) {
    for (std::size_t i = 0; i < op.GetNumberOfExtentions(); ++i) {
        if (auto* ext = dynamic_cast<Operator_Ext_Excitation*>(op.GetExtension(i))) {
            return ext;
        }
    }
    return nullptr;
}

std::vector<CopperExcitationCell> extractCells(unsigned int count, unsigned int* const index[3],
                                                unsigned short* dir, FDTD_FLOAT* amp, unsigned int* delay) {
    std::vector<CopperExcitationCell> cells(count);
    for (unsigned int n = 0; n < count; ++n) {
        cells[n].x = index[0][n];
        cells[n].y = index[1][n];
        cells[n].z = index[2][n];
        cells[n].axis = dir[n];
        cells[n].amplitude = amp[n];
        cells[n].delaySteps = delay[n];
    }
    return cells;
}

} // namespace

CopperExcitation buildExcitation(Operator& op) {
    CopperExcitation result;

    Excitation* exc = op.GetExcitationSignal();
    if (exc == nullptr) {
        return result;
    }
    const unsigned int length = exc->GetLength();
    result.voltageSignal.assign(exc->GetVoltageSignal(), exc->GetVoltageSignal() + length);
    result.currentSignal.assign(exc->GetCurrentSignal(), exc->GetCurrentSignal() + length);
    result.signalPeriodSeconds = exc->GetSignalPeriod();

    Operator_Ext_Excitation* extBase = findExcitationExtension(op);
    if (extBase == nullptr) {
        return result; // No excitation properties on this CSX -- matches openEMS's own tolerance.
    }
    auto* ext = static_cast<CopperExcitationAccess*>(extBase);

    result.voltageCells =
        extractCells(ext->Volt_Count, ext->Volt_index, ext->Volt_dir, ext->Volt_amp, ext->Volt_delay);
    result.currentCells =
        extractCells(ext->Curr_Count, ext->Curr_index, ext->Curr_dir, ext->Curr_amp, ext->Curr_delay);

    return result;
}

} // namespace copper
