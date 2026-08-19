#include "CopperPML.hpp"

#include "CopperOpenEMSAccess.hpp"

namespace copper {

namespace {

void extractShellCoefficients(CopperUPMLAccess& ext, const CopperGridDims& dims, unsigned int axis,
                               std::vector<float>& vv, std::vector<float>& vvfo, std::vector<float>& vvfn,
                               std::vector<float>& ii, std::vector<float>& iifo, std::vector<float>& iifn) {
    const std::uint32_t count = dims.cellCount();
    vv.resize(count);
    vvfo.resize(count);
    vvfn.resize(count);
    ii.resize(count);
    iifo.resize(count);
    iifn.resize(count);

    unsigned int pos[3];
    for (pos[2] = 0; pos[2] < dims.nz; ++pos[2]) {
        for (pos[1] = 0; pos[1] < dims.ny; ++pos[1]) {
            for (pos[0] = 0; pos[0] < dims.nx; ++pos[0]) {
                const std::uint32_t idx = copperGridIndex(dims, pos[0], pos[1], pos[2]);
                vv[idx] = ext.GetVV(static_cast<int>(axis), pos);
                vvfo[idx] = ext.GetVVFO(static_cast<int>(axis), pos);
                vvfn[idx] = ext.GetVVFN(static_cast<int>(axis), pos);
                ii[idx] = ext.GetII(static_cast<int>(axis), pos);
                iifo[idx] = ext.GetIIFO(static_cast<int>(axis), pos);
                iifn[idx] = ext.GetIIFN(static_cast<int>(axis), pos);
            }
        }
    }
}

} // namespace

std::vector<CopperPMLShell> buildPMLShells(Operator& op) {
    std::vector<CopperPMLShell> shells;
    for (std::size_t i = 0; i < op.GetNumberOfExtentions(); ++i) {
        auto* extBase = dynamic_cast<Operator_Ext_UPML*>(op.GetExtension(i));
        if (extBase == nullptr) {
            continue;
        }
        auto* ext = static_cast<CopperUPMLAccess*>(extBase);

        CopperPMLShell shell;
        shell.startX = ext->m_StartPos[0];
        shell.startY = ext->m_StartPos[1];
        shell.startZ = ext->m_StartPos[2];
        shell.dims.nx = ext->m_numLines[0];
        shell.dims.ny = ext->m_numLines[1];
        shell.dims.nz = ext->m_numLines[2];

        for (unsigned int axis = 0; axis < 3; ++axis) {
            extractShellCoefficients(*ext, shell.dims, axis, shell.vv[axis], shell.vvfo[axis], shell.vvfn[axis],
                                      shell.ii[axis], shell.iifo[axis], shell.iifn[axis]);
        }

        shells.push_back(std::move(shell));
    }
    return shells;
}

} // namespace copper
