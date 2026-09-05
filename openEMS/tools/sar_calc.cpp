/*
*	Copyright (C) 2025 Thorsten Liebig (Thorsten.Liebig@gmx.de)
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#include <iostream>
#include <CopperUtils/ThirdParty/CLI11/CLI11.hpp>

#include "sar_calculation.h"

using namespace std;

int main(int argc, char *argv[])
{
	cout << " ---------------------------------------------------------------------- " << endl;
	cout << " | SAR calculation for openEMS "                                          << endl;
	cout << " | (C) 2012-2026 Thorsten Liebig <thorsten.liebig@gmx.de>  GPL license"   << endl;
	cout << " ---------------------------------------------------------------------- " << endl;

	string ifile, ofile, method = "SIMPLE";
	double m_avg = 0;
	double auto_range = 0;
	bool debug = false;
	bool export_cube_stats = false;
	bool legacyHDF5 = false;
	bool progress = false;
	unsigned int numThreads = 0;

	CLI::App options{"Options", "sar_calc"};
	options.add_option("-i,--input", ifile, "Pathname to input HDF5 file")->required();
	options.add_option("-o,--output", ofile, "Pathname for output HDF5 file")->required();
	options.add_option("--method", method, "SAR method: IEEE_C95_3, IEEE_62704, or SIMPLE");
	options.add_option("-m,--mass", m_avg, "Averaging mass in g");
	options.add_option("-a,--autorange", auto_range, "Value limit in dB from maximum (>0)");
	options.add_option("-n,--numThreads", numThreads, "Number of threads");
	options.add_flag("-v,--verbose", debug, "Verbose output");
	options.add_flag("-p,--progress", progress, "Show progress");
	options.add_flag("-e,--export_cube_stats", export_cube_stats, "Export cube statistics");
	options.add_flag("--legacyHDF5Dumps", legacyHDF5, "Use the legacy HDF5 format for Matlab/Octave");

	try
	{
		options.parse(argc, argv);
	}
	catch (const CLI::ParseError& error)
	{
		return options.exit(error);
	}

	SAR_Calculation sar_calc;
	sar_calc.SetDebugLevel(int(debug));
	sar_calc.EnableProgress(progress);
	sar_calc.SetAveragingMass(m_avg/1000);
	sar_calc.EnableAutoRange(auto_range);
	if (export_cube_stats)
		sar_calc.EnableCubeStats();
	if (!sar_calc.SetAveragingMethod(method, !debug))
		return -1;
	return sar_calc.CalcFromHDF5(ifile, ofile, legacyHDF5, numThreads);
}
