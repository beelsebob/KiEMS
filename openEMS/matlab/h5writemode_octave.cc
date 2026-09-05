#include <octave/oct.h>
#include <vector>
#include "hdf5.h"

// Write a 1-D double dataset into an already-open HDF5 file.
static herr_t write_dataset_1d(hid_t fid, const char* name,
                                const double* data, hsize_t n)
{
    hid_t  dspace = H5Screate_simple(1, &n, NULL);
    hid_t  dset   = H5Dcreate2(fid, name, H5T_NATIVE_DOUBLE, dspace,
                                H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    herr_t ret    = H5Dwrite(dset, H5T_NATIVE_DOUBLE,
                              H5S_ALL, H5S_ALL, H5P_DEFAULT, data);
    H5Dclose(dset);
    H5Sclose(dspace);
    return ret;
}

// Write a 2-D double dataset (C row-major, dims nx × ny) into an open file.
static herr_t write_dataset_2d(hid_t fid, const char* name,
                                const double* data, hsize_t nx, hsize_t ny)
{
    hsize_t dims[2] = {nx, ny};
    hid_t  dspace = H5Screate_simple(2, dims, NULL);
    hid_t  dset   = H5Dcreate2(fid, name, H5T_NATIVE_DOUBLE, dspace,
                                H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    herr_t ret    = H5Dwrite(dset, H5T_NATIVE_DOUBLE,
                              H5S_ALL, H5S_ALL, H5P_DEFAULT, data);
    H5Dclose(dset);
    H5Sclose(dspace);
    return ret;
}

DEFUN_DLD (h5writemode_octave, args, nargout,
    "h5writemode_octave(filename, x, y, Vx, Vy)\n"
    "\n"
    "Write a 2-D mode field profile to an HDF5 file in the format\n"
    "expected by AddWaveGuidePort / CSModeData.\n"
    "\n"
    "  filename : output file path (overwritten if it exists)\n"
    "  x, y     : coordinate vectors (length nx and ny)\n"
    "  Vx, Vy   : field component matrices (nx-by-ny),\n"
    "             where Vx(i,j) is the field at (x(i), y(j))\n"
    "\n"
    "HDF5 layout written:\n"
    "  /x   1-D, length nx\n"
    "  /y   1-D, length ny\n"
    "  /Vx  2-D, shape nx x ny  (C row-major)\n"
    "  /Vy  2-D, shape nx x ny  (C row-major)\n"
    "  root attribute Version = 1.0\n")
{
    if (args.length() != 5)
    {
        print_usage();
        return octave_value();
    }

    std::string filename = args(0).string_value();
    Matrix x_mat  = args(1).matrix_value();
    Matrix y_mat  = args(2).matrix_value();
    Matrix Vx_mat = args(3).matrix_value();
    Matrix Vy_mat = args(4).matrix_value();

    hsize_t nx = (hsize_t)x_mat.numel();
    hsize_t ny = (hsize_t)y_mat.numel();

    if ((hsize_t)Vx_mat.rows() != nx || (hsize_t)Vx_mat.cols() != ny)
    {
        error("h5writemode_octave: Vx must be %d-by-%d, got %d-by-%d",
              (int)nx, (int)ny, (int)Vx_mat.rows(), (int)Vx_mat.cols());
        return octave_value();
    }
    if ((hsize_t)Vy_mat.rows() != nx || (hsize_t)Vy_mat.cols() != ny)
    {
        error("h5writemode_octave: Vy must be %d-by-%d, got %d-by-%d",
              (int)nx, (int)ny, (int)Vy_mat.rows(), (int)Vy_mat.cols());
        return octave_value();
    }

    H5Eset_auto2(H5E_DEFAULT, NULL, NULL);

    hid_t fid = H5Fcreate(filename.c_str(), H5F_ACC_TRUNC,
                           H5P_DEFAULT, H5P_DEFAULT);
    if (fid < 0)
    {
        error("h5writemode_octave: cannot create file '%s'", filename.c_str());
        return octave_value();
    }

    // 1-D coordinate vectors
    std::vector<double> x_buf(nx), y_buf(ny);
    for (hsize_t i = 0; i < nx; i++) x_buf[i] = x_mat(i);
    for (hsize_t j = 0; j < ny; j++) y_buf[j] = y_mat(j);
    write_dataset_1d(fid, "x", x_buf.data(), nx);
    write_dataset_1d(fid, "y", y_buf.data(), ny);

    // 2-D field matrices: Octave is column-major, HDF5/C++ is row-major.
    // Vx_mat(i,j) must land at flat index i*ny+j — requires a transposition.
    std::vector<double> vx_buf(nx * ny), vy_buf(nx * ny);
    for (hsize_t i = 0; i < nx; i++)
        for (hsize_t j = 0; j < ny; j++)
        {
            vx_buf[i * ny + j] = Vx_mat(i, j);
            vy_buf[i * ny + j] = Vy_mat(i, j);
        }
    write_dataset_2d(fid, "Vx", vx_buf.data(), nx, ny);
    write_dataset_2d(fid, "Vy", vy_buf.data(), nx, ny);

    // Root Version attribute
    double version = 1.0;
    hid_t scalar   = H5Screate(H5S_SCALAR);
    hid_t attr     = H5Acreate2(fid, "Version", H5T_NATIVE_DOUBLE,
                                 scalar, H5P_DEFAULT, H5P_DEFAULT);
    H5Awrite(attr, H5T_NATIVE_DOUBLE, &version);
    H5Aclose(attr);
    H5Sclose(scalar);

    H5Fclose(fid);
    return octave_value();
}
