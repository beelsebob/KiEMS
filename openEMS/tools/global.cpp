/*
* Copyright (C) 2024 Yifeng Li <tomli@tomli.me>
* Copyright (C) 2010 Sebastian Held (sebastian.held@gmx.de)
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*/

#include <cstdlib>
#include <iostream>
#include "global.h"
#include <CopperUtils/ThirdParty/CLI11/CLI11.hpp>

using namespace std;

Global g_settings;

Global::Global()
{
	m_showProbeDiscretization = false;
	m_nativeFieldDumps = false;
	m_legacyHDF5 = false;
	m_VerboseLevel = 0;
	m_SavedVerboseLevel = 0;
	m_optionDesc = NULL;
}

Global::~Global()
{
	clearOptionDesc();
}

CLI::App& Global::optionDesc()
{
	if (m_optionDesc == NULL)
	{
		m_optionDesc = new CLI::App("Options", "openEMS");
		m_optionDesc->option_defaults()->ignore_case();
		m_optionDesc->add_option("FDTD_XML_FILE", m_inputFile, "FDTD XML input file");
	}
	return *m_optionDesc;
}

void Global::appendGlobalOptions()
{
	CLI::App& options = optionDesc();
	options.add_flag_callback("--showProbeDiscretization", [&]() {
		cout << "openEMS - showing probe discretization information" << endl;
		m_showProbeDiscretization = true;
	}, "Show probe discretization information");
	options.add_flag_callback("--nativeFieldDumps", [&]() {
		cout << "openEMS - dumping all fields using the native field components" << endl;
		m_nativeFieldDumps = true;
	}, "Dump fields using their native components");
	options.add_flag_callback("--legacyHDF5Dumps", [&]() {
		cout << "openEMS - dumping using the legacy HDF5 file format" << endl;
		m_legacyHDF5 = true;
	}, "Dump using the legacy HDF5 file format");
	options.add_flag_function("-v,--verbose", [&](std::int64_t count) {
		m_VerboseLevel = static_cast<int>(count);
		cout << "openEMS - verbose level " << m_VerboseLevel << endl;
	}, "Increase verbosity; accepts -v, -vv, and -vvv");
}

void Global::clearOptionDesc()
{
	delete m_optionDesc;
	m_optionDesc = NULL;
	m_inputFile.clear();
}

void Global::parseLibraryArguments(std::vector<std::string> allOptions)
{
	vector<string> arguments;
	arguments.emplace_back("openEMS");
	for (const string& option : allOptions)
	{
		if (option.length() == 1)
			arguments.emplace_back("-" + option);
		else
			arguments.emplace_back("--" + option);
	}

	vector<const char*> argv;
	argv.reserve(arguments.size());
	for (const auto& argument : arguments)
		argv.push_back(argument.c_str());
	m_optionDesc->parse(static_cast<int>(argv.size()), argv.data());
}

void Global::parseCommandLineArguments(int argc, const char* argv[])
{
	try
	{
		m_optionDesc->parse(argc, argv);
	}
	catch (const CLI::ParseError& error)
	{
		std::exit(m_optionDesc->exit(error));
	}
}

void Global::showOptionUsage(std::ostream& ostr)
{
	ostr << m_optionDesc->help() << endl;
}
