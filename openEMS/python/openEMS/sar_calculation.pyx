# -*- coding: utf-8 -*-
#
# Copyright (C) 2025 Thorsten Liebig (Thorsten.Liebig@gmx.de)
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

cimport openEMS.sar_calculation
import os

cdef class SAR_Calculation:
    """SAR averaging and calculation.

    Keyword arguments accepted by the constructor (all optional):

    mass : float
        Averaging mass in grams (0 = local SAR, default 0).
    method : str
        Averaging method: 'SIMPLE', 'IEEE_C95_3', or 'IEEE_62704'.
    verbose : int
        Debug verbosity level.
    autoRange : float
        Restrict calculation to cells within this many dB of the peak
        local power density.
    EnableCubeStats : bool
        Record per-cube averaging statistics in the output file.
    """
    def __cinit__(self, **kw):
        self.thisptr = new _SAR_Calculation()
        for k, v in kw.items():
            if k == 'mass':
                self.SetAveragingMass(v)
            elif k=='method':
                self.SetAveragingMethod(v)
            elif k=='verbose':
                self.SetDebugLevel(int(v))
            elif k=='debug':
                self.SetDebugLevel(int(v))
            elif k=='autoRange':
                self.EnableAutoRange(float(v))
            elif k=='EnableCubeStats':
                if v:
                    self.EnableCubeStats()
            else:
                raise Exception('Unknown keyword argument: "{}"'.format(k))

    def __dealloc__(self):
        del self.thisptr

    def SetDebugLevel(self, level):
        self.thisptr.SetDebugLevel(level)

    def EnableProgress(self, enable):
        self.thisptr.EnableProgress(enable)

    def SetAveragingMass(self, mass):
        """Set averaging mass in grams (0 = local SAR)."""
        self.thisptr.SetAveragingMass(float(mass)/1000)

    def SetAveragingMethod(self, method, silent=True):
        """Set averaging method. Valid values: 'SIMPLE', 'IEEE_C95_3', 'IEEE_62704'.
        Returns True on success, False if the method name is unknown."""
        return self.thisptr.SetAveragingMethod(method.encode('UTF-8'), silent)

    def EnableAutoRange(self, dBmax):
        self.thisptr.EnableAutoRange(float(dBmax))

    def EnableCubeStats(self):
        self.thisptr.EnableCubeStats()

    def CalcFromHDF5(self, h5_fn, out_name, export_cube_stats=False, numThreads=0):
        """Read raw field data from h5_fn, run the SAR calculation, and write
        results to out_name. Returns True on success.
        numThreads=0 uses all available hardware threads."""
        if not os.path.exists(h5_fn):
            raise Exception('File "{}" does not exist'.format(h5_fn))
        cdef string in_fn = h5_fn.encode('UTF-8')
        cdef string out_fn = out_name.encode('UTF-8')
        cdef unsigned int c_numThreads = numThreads
        if export_cube_stats:
            self.EnableCubeStats()
        with nogil:
            ok = self.thisptr.CalcFromHDF5(in_fn, out_fn, False, c_numThreads)
        return ok

