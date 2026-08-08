// Registers a headless placeholder for KiCad's "tuning_pattern" PCB_GENERATOR (length-tuning
// meander patterns), the only generator type this KiCad version has. Without this,
// PCB_IO_KICAD_SEXPR::LoadBoard() throws IO_ERROR on any board using one, since the real
// PCB_TUNING_PATTERN (pcbnew/generators/pcb_tuning_pattern.cpp) lives in the GUI-only
// pcbnew_kiface_objects target and is never linked here.
//
// GENERATORS_MGR is a simple, intentional extension point (see generators_mgr.h) -- registering
// our own minimal PCB_GENERATOR here is using that mechanism as designed, not working around it.
// The real class's pure-virtual surface (EditStart/Update/EditFinish/EditCancel/Remove,
// GetPluralName/GetCommitMessage) is entirely interactive-editing plumbing that a headless
// GetItems query never touches; this placeholder exists purely so parsing a board that contains
// one doesn't throw. Its actual meander geometry is not reconstructed -- board content this
// smoketest cares about (pads, footprints, zones) isn't stored on the generator itself.
#include "libkicad_generators.hpp"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"

#include <generators_mgr.h>
#include <pcb_generator.h>

namespace {

class HeadlessTuningPattern : public PCB_GENERATOR {
public:
    static const wxString GENERATOR_TYPE;
    static const wxString DISPLAY_NAME;

    explicit HeadlessTuningPattern(BOARD_ITEM* aParent = nullptr, PCB_LAYER_ID aLayer = F_Cu)
            : PCB_GENERATOR(aParent, aLayer) {
        m_generatorType = GENERATOR_TYPE;
    }

    void EditStart(GENERATOR_TOOL*, BOARD*, BOARD_COMMIT*) override {}
    bool Update(GENERATOR_TOOL*, BOARD*, BOARD_COMMIT*) override {
        return false;
    }
    void EditFinish(GENERATOR_TOOL*, BOARD*, BOARD_COMMIT*) override {}
    void EditCancel(GENERATOR_TOOL*, BOARD*, BOARD_COMMIT*) override {}
    void Remove(GENERATOR_TOOL*, BOARD*, BOARD_COMMIT*) override {}

    // BOARD_ITEM::SetLayerSet()'s default only handles single-layer sets by delegating to
    // SetLayer(); anything else is UNIMPLEMENTED_FOR(). PCB_GROUP already treats SetLayer() as a
    // no-op (groups aren't themselves layer-bound, their members are), so follow the same
    // philosophy here instead of inheriting the single-layer-only default.
    void SetLayerSet(const LSET&) override {}

    wxString GetPluralName() const override {
        return DISPLAY_NAME;
    }
    wxString GetCommitMessage() const override {
        return DISPLAY_NAME;
    }
};

const wxString HeadlessTuningPattern::GENERATOR_TYPE = wxS("tuning_pattern");
const wxString HeadlessTuningPattern::DISPLAY_NAME = wxS("Tuning Pattern (unsupported in libkicad)");

GENERATORS_MGR::REGISTER<HeadlessTuningPattern> registerHeadlessTuningPattern;

} // namespace

#pragma clang diagnostic pop

namespace libkicad::detail {

// Nothing else in this library calls anything defined in this translation unit -- its only job
// is the static registerHeadlessTuningPattern object's constructor above. A .o with no
// externally-referenced symbols is simply dropped when linked from a static library (ar/ld only
// pull in archive members needed to resolve a reference), which silently skips that constructor
// too. Giving the file one real, callable function and calling it from countPadsRaw() forces the
// linker to keep this member.
void ensureGeneratorsRegistered() {}

} // namespace libkicad::detail
