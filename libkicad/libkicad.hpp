#pragma once

#include <string>

// Experimental proof-of-concept: load a real .kicad_pcb headlessly and query it via the same
// API_HANDLER_PCB / protobuf command path KiCad's own IPC API server uses, without any
// PCB_EDIT_FRAME, KIWAY, or wx GUI window. See geber2ems/libkicad/libkicad.cpp for the chain
// this exercises: SETTINGS_MANAGER -> PCB_IO_KICAD_SEXPR -> HEADLESS_PCB_CONTEXT ->
// API_HANDLER_PCB::Handle(GetItems).
struct LibKicadPadQueryResult
{
    bool success = false;
    std::string errorMessage;
    int footprintCount = 0;
    int trackCount = 0;
    int zoneCount = 0;
    int padCount = 0;
};

LibKicadPadQueryResult LibKicadCountPads( const std::string& projectPath, const std::string& boardPath );
