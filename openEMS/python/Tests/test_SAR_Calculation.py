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

import unittest

from openEMS.sar_calculation import SAR_Calculation


class Test_Constructor(unittest.TestCase):
    def test_unknown_kwarg_raises(self):
        with self.assertRaises(Exception):
            SAR_Calculation(UnknownOption=42)

    def test_unknown_kwarg_message(self):
        with self.assertRaises(Exception) as ctx:
            SAR_Calculation(badkwarg=1)
        self.assertIn('badkwarg', str(ctx.exception))

    def test_all_known_kwargs_accepted(self):
        SAR_Calculation(mass=10.0, method='SIMPLE', verbose=1,
                        autoRange=30.0, EnableCubeStats=True)


class Test_SetAveragingMethod(unittest.TestCase):
    def setUp(self):
        self.sar = SAR_Calculation()

    def test_valid_methods(self):
        for method in ('SIMPLE', 'IEEE_C95_3', 'IEEE_62704'):
            with self.subTest(method=method):
                self.assertTrue(self.sar.SetAveragingMethod(method))

    def test_invalid_method_returns_false(self):
        self.assertFalse(self.sar.SetAveragingMethod('INVALID'))

    def test_empty_string_returns_false(self):
        self.assertFalse(self.sar.SetAveragingMethod(''))


class Test_CalcFromHDF5(unittest.TestCase):
    def setUp(self):
        self.sar = SAR_Calculation()

    def test_nonexistent_file_raises_with_filename(self):
        h5_fn = '/nonexistent/path/sar_result.h5'
        with self.assertRaises(Exception) as ctx:
            self.sar.CalcFromHDF5(h5_fn, '/tmp/out_sar')
        self.assertIn(h5_fn, str(ctx.exception))


if __name__ == '__main__':
    unittest.main()
