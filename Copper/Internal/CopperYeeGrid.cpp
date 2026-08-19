#include "CopperYeeGrid.hpp"

namespace copper {

namespace {

std::vector<float> extractPrimaryLine(Operator& op, int axis, std::uint32_t count, double gridDelta) {
    std::vector<float> lines(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        lines[i] = static_cast<float>(op.GetDiscLine(axis, i, /*dualMesh=*/false) * gridDelta);
    }
    return lines;
}

std::vector<float> extractDualLine(Operator& op, int axis, std::uint32_t count, double gridDelta) {
    std::vector<float> lines(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        lines[i] = static_cast<float>(op.GetDiscLine(axis, i, /*dualMesh=*/true) * gridDelta);
    }
    return lines;
}

void extractCoefficients(Operator& op, const CopperGridDims& dims, unsigned int axis, std::vector<float>& vv,
                          std::vector<float>& vi, std::vector<float>& ii, std::vector<float>& iv) {
    const std::uint32_t count = dims.cellCount();
    vv.resize(count);
    vi.resize(count);
    ii.resize(count);
    iv.resize(count);
    for (std::uint32_t z = 0; z < dims.nz; ++z) {
        for (std::uint32_t y = 0; y < dims.ny; ++y) {
            for (std::uint32_t x = 0; x < dims.nx; ++x) {
                const std::uint32_t idx = copperGridIndex(dims, x, y, z);
                vv[idx] = op.GetVV(axis, x, y, z);
                vi[idx] = op.GetVI(axis, x, y, z);
                ii[idx] = op.GetII(axis, x, y, z);
                iv[idx] = op.GetIV(axis, x, y, z);
            }
        }
    }
}

} // namespace

CopperYeeGrid buildYeeGrid(Operator& op) {
    CopperYeeGrid grid;
    grid.dims.nx = op.GetNumberOfLines(0);
    grid.dims.ny = op.GetNumberOfLines(1);
    grid.dims.nz = op.GetNumberOfLines(2);
    grid.timestepSeconds = op.GetTimestep();

    const double gridDelta = op.GetGridDelta();
    grid.lineX = extractPrimaryLine(op, 0, grid.dims.nx, gridDelta);
    grid.lineY = extractPrimaryLine(op, 1, grid.dims.ny, gridDelta);
    grid.lineZ = extractPrimaryLine(op, 2, grid.dims.nz, gridDelta);
    grid.dualLineX = extractDualLine(op, 0, grid.dims.nx, gridDelta);
    grid.dualLineY = extractDualLine(op, 1, grid.dims.ny, gridDelta);
    grid.dualLineZ = extractDualLine(op, 2, grid.dims.nz, gridDelta);

    for (unsigned int axis = 0; axis < 3; ++axis) {
        extractCoefficients(op, grid.dims, axis, grid.vv[axis], grid.vi[axis], grid.ii[axis], grid.iv[axis]);
    }

    return grid;
}

} // namespace copper
