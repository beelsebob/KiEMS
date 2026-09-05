/*
* Copyright (C) 2024 Yifeng Li <tomli@tomli.me>
* Copyright (C) 2010 Sebastian Held (sebastian.held@gmx.de)
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*/

#ifndef GLOBAL_H
#define GLOBAL_H

#include <sstream>
#include <string>
#include <vector>
#define _USE_MATH_DEFINES

#include "openems_global.h"

namespace CLI
{
class App;
}

#define UNUSED(x) (void)(x);

class OPENEMS_EXPORT Global
{
public:
	Global();
	~Global();

	bool showProbeDiscretization() const {return m_showProbeDiscretization;}
	bool NativeFieldDumps() const {return m_nativeFieldDumps;}
	void SetNativeFieldDumps(bool val) {m_nativeFieldDumps=val;}
	void SetLegacyHDF5Dumps(bool val) {m_legacyHDF5=val;}
	bool GetLegacyHDF5Dumps() const {return m_legacyHDF5;}

	void SetVerboseLevel(int level) {m_VerboseLevel=level;m_SavedVerboseLevel=level;}
	int GetVerboseLevel() const {return m_VerboseLevel;}
	void SetTempVerboseLevel(int level) {m_SavedVerboseLevel=m_VerboseLevel;m_VerboseLevel=level;}
	void RestoreVerboseLevel() {m_VerboseLevel=m_SavedVerboseLevel;}

	// The parser is rebuilt whenever a new openEMS instance collects its callbacks. This preserves
	// the existing shared-library behaviour while replacing Boost.Program_options with CLI11.
	CLI::App& optionDesc();
	void appendGlobalOptions();
	void clearOptionDesc();

	void parseLibraryArguments(std::vector<std::string> allOptions);
	void parseCommandLineArguments(int argc, const char* argv[]);
	void showOptionUsage(std::ostream& ostr);

protected:
	bool m_showProbeDiscretization;
	bool m_nativeFieldDumps;
	bool m_legacyHDF5;
	int m_VerboseLevel;
	int m_SavedVerboseLevel;
	CLI::App* m_optionDesc;
	std::string m_inputFile;
};

OPENEMS_EXPORT extern Global g_settings;

#endif // GLOBAL_H
