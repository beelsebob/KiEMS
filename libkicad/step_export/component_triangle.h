#ifndef LIBKICAD_STEP_EXPORT_COMPONENT_TRIANGLE_H
#define LIBKICAD_STEP_EXPORT_COMPONENT_TRIANGLE_H

// Deliberately its own tiny, dependency-free header (no OCCT/KiCad includes at all) rather than a
// nested type of STEP_PCB_MODEL: exporter_step.h only forward-declares STEP_PCB_MODEL (its own
// full definition pulls in enough of OCCT/KiCad's own headers, in a fragile enough include order,
// that including step_pcb_model.h from exporter_step.h broke unrelated translation units elsewhere
// in this project -- SHAPE_SEGMENT/EXTRUSION_MATERIAL going unknown in step_pcb_model.h itself, and
// a macro collision surfacing all the way over in libkicad.cpp's own use of API_HANDLER_PCB). Both
// exporter_step.h (EXPORTER_STEP::GetComponentTriangles) and step_pcb_model.h
// (STEP_PCB_MODEL::GetComponentTriangles) need this same plain struct in their own public
// signatures without pulling the other's heavy includes in, so it lives here instead.

/// One mesh triangle from STEP_PCB_MODEL::GetComponentTriangles()/EXPORTER_STEP::GetComponentTriangles()
/// -- see their own doc comments for exactly what coordinate frame/units/color source this is.
struct STEP_COMPONENT_TRIANGLE
{
    double ax, ay, az;
    double bx, by, bz;
    double cx, cy, cz;
    double r, g, b, a;
};

#endif
