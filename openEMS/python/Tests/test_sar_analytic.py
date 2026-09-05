# -*- coding: utf-8 -*-
#
# Copyright (C) 2026 Thorsten Liebig (Thorsten.Liebig@gmx.de)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

"""Analytic and consistency tests for the SAR pipeline.

  - Local SAR = σ|E|²/(2ρ) verified against analytic formula
  - Two frequencies → both produce output
  - numThreads=1 vs numThreads=4 give bit-identical arrays (race-fix validation)
"""

import os
import tempfile
import unittest
import numpy as np
import h5py

from openEMS.sar_calculation import SAR_Calculation
from openEMS.sar_utils import readSAR


def _make_raw_sar_hdf5(path, nx=4, ny=4, nz=4, cell_dx=1e-3,
                        conductivity=0.5, density=1000.0, e_field_x=1.0,
                        frequencies=None):
    """Write a raw SAR data HDF5 file matching the ProcessFieldsSAR format."""
    if frequencies is None:
        frequencies = [2.4e9]

    complex_dtype = np.dtype([('r', np.float32), ('i', np.float32)])

    cond_arr = np.empty((nx, ny, nz), dtype=np.float32); cond_arr[...] = conductivity
    dens_arr = np.empty((nx, ny, nz), dtype=np.float32); dens_arr[...] = density

    with h5py.File(path, 'w') as h5:
        h5.attrs['openEMS_HDF5_version'] = np.float64(0.3)

        for grp, n in (('Mesh', (nx, ny, nz)), ('CellWidth', (nx, ny, nz))):
            for axis, size in zip('xyz', n):
                h5['{}/{}'.format(grp, axis)] = ((np.arange(size) + 0.5) * cell_dx
                                       if grp == 'Mesh'
                                       else np.full(size, cell_dx)).astype(np.float64)

        h5['/CellData/Density']      = dens_arr
        h5['/CellData/Conductivity'] = cond_arr
        h5['/CellData/Volume']       = np.full((nx, ny, nz), cell_dx**3, dtype=np.float32)

        fd_grp = h5.require_group('/FieldData/FD')
        fd_grp.attrs['frequency'] = np.array(frequencies, dtype=np.float64)
        for n_idx in range(len(frequencies)):
            e_data = np.zeros((3, nx, ny, nz), dtype=complex_dtype)
            e_data[0, :, :, :]['r'] = e_field_x
            h5['/FieldData/FD/f{}'.format(n_idx)] = e_data


class _TempFiles:
    """Mixin: setUp creates self.in_path and self.out_path temp files."""
    _make_kw = {}

    def setUp(self):
        fd, self.in_path = tempfile.mkstemp(suffix='.h5')
        os.close(fd)
        fd, self.out_path = tempfile.mkstemp(suffix='.h5')
        os.close(fd)
        os.unlink(self.out_path)
        _make_raw_sar_hdf5(self.in_path, **self._make_kw)

    def tearDown(self):
        for p in (self.in_path, self.out_path):
            if os.path.exists(p):
                os.unlink(p)


class Test_LocalSAR_Analytic(_TempFiles, unittest.TestCase):
    """Local SAR = σ|E|²/(2ρ) on a 4×4×4 uniform phantom."""

    _make_kw = dict(nx=4, ny=4, nz=4, cell_dx=1e-3,
                    conductivity=0.5, density=1000.0, e_field_x=1.0)

    EXPECTED = 0.5 * 1.0**2 / (2.0 * 1000.0)  # 2.5e-4 W/kg

    def _calc(self):
        ok = SAR_Calculation(mass=0.0).CalcFromHDF5(self.in_path, self.out_path)
        self.assertTrue(ok)
        return readSAR(self.out_path)

    def test_sar_analytic_value(self):
        sar, _, _ = self._calc()
        np.testing.assert_allclose(sar, self.EXPECTED, rtol=1e-5)

    def test_all_cells_uniform(self):
        sar, _, _ = self._calc()
        self.assertEqual(float(sar.min()), float(sar.max()))

    def test_max_sar_attribute_correct(self):
        sar, _, data = self._calc()
        self.assertAlmostEqual(float(data['maxSAR']), self.EXPECTED, places=7)


class Test_TwoFrequencies(_TempFiles, unittest.TestCase):
    """Both frequencies produce an output dataset of the right shape."""

    _make_kw = dict(nx=4, ny=4, nz=4, cell_dx=1e-3,
                    conductivity=0.3, density=800.0, e_field_x=2.0,
                    frequencies=[1e9, 2e9])

    def setUp(self):
        super().setUp()
        SAR_Calculation(mass=0.0).CalcFromHDF5(self.in_path, self.out_path)

    def test_both_frequency_datasets_present(self):
        for f_idx in (0, 1):
            with self.subTest(f_idx=f_idx):
                sar, _, _ = readSAR(self.out_path, f_idx=f_idx)
                self.assertEqual(sar.shape, (4, 4, 4))


class Test_ThreadConsistency(unittest.TestCase):
    """numThreads=1 and numThreads=4 produce bit-identical SAR arrays.

    Validates the race-condition fix in CalcAvgStep1SAR / CalcAvgStep2SAR.
    10×10×10 grid with 2 mm cells and 1 g averaging mass.
    """

    NX = NY = NZ = 10
    CELL_DX = 2e-3
    MASS_G  = 1.0

    def setUp(self):
        fd, self.in_path = tempfile.mkstemp(suffix='.h5')
        os.close(fd)
        fd, self.out1 = tempfile.mkstemp(suffix='.h5')
        os.close(fd)
        fd, self.out4 = tempfile.mkstemp(suffix='.h5')
        os.close(fd)
        os.unlink(self.out1)
        os.unlink(self.out4)

        rng = np.random.RandomState(seed=42)
        cond = rng.uniform(0.1, 1.0, (self.NX, self.NY, self.NZ)).astype(np.float32)
        _make_raw_sar_hdf5(self.in_path,
                           nx=self.NX, ny=self.NY, nz=self.NZ,
                           cell_dx=self.CELL_DX, conductivity=cond,
                           density=1000.0, e_field_x=1.0)

    def tearDown(self):
        for p in (self.in_path, self.out1, self.out4):
            if os.path.exists(p):
                os.unlink(p)

    def _run(self, out_path, num_threads):
        ok = SAR_Calculation(mass=self.MASS_G).CalcFromHDF5(
            self.in_path, out_path, numThreads=num_threads)
        self.assertTrue(ok)
        return readSAR(out_path)

    def test_single_vs_four_threads_identical(self):
        sar1, _, _ = self._run(self.out1, num_threads=1)
        sar4, _, _ = self._run(self.out4, num_threads=4)
        np.testing.assert_array_equal(sar1, sar4)

    def test_max_sar_matches_array_max(self):
        for out, n in ((self.out1, 1), (self.out4, 4)):
            with self.subTest(numThreads=n):
                sar, _, data = self._run(out, num_threads=n)
                self.assertAlmostEqual(float(data['maxSAR']), float(sar.max()), places=5)


if __name__ == '__main__':
    unittest.main()
