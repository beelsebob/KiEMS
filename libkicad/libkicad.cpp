#include "libkicad_generators.hpp"
#include "libkicad_result.hpp"

#include <cstdint>
#include <memory>

// KiCad and wx headers aren't built against this project's strict warning settings and aren't
// ours to fix; silence their diagnostics for the includes and the rest of this file, since some
// of their inline/template bodies are only checked where we actually use them below.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"

#include <wx/app.h>
#include <wx/init.h>
#include <wx/filename.h>

#include <pgm_base.h>
#include <settings/settings_manager.h>
#include <project.h>
#include <board.h>
#include <pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.h>
#include <api/headless_pcb_context.h>
#include <api/api_handler_pcb.h>

#include <api/common/commands/base_commands.pb.h>
#include <api/common/envelope.pb.h>
#include <api/common/types/base_types.pb.h>

#pragma clang diagnostic pop

namespace libkicad::detail {

namespace {

// PGM_BASE has exactly one pure-virtual method; a minimal, non-mock, real subclass covers it.
class MinimalPgm : public PGM_BASE {
public:
    void MacOpenFile(const wxString&) override {}
};

bool _ensureWxInitialized() {
    static bool initialized = false;
    if (initialized) {
        return true;
    }

    wxApp::SetInstance(new wxAppConsole());
    int argc = 0;
    bool wxInitOk = wxInitialize(argc, static_cast<char**>(nullptr));
    if (!wxInitOk) {
        return false;
    }

    SetPgm(new MinimalPgm());

    // Real initialization, not a stub: sets up the process-wide SETTINGS_MANAGER that
    // LIBRARY_MANAGER and friends reach via Pgm().GetSettingsManager(). Skipping this leaves
    // that unique_ptr null and crashes the first time anything follows that path.
    bool pgmInitOk = Pgm().InitPgm(/* aHeadless = */ true);
    if (!pgmInitOk) {
        return false;
    }

    initialized = true;
    return true;
}

RawPadCountsResult _fail(std::string error) {
    RawPadCountsResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

} // namespace

RawPadCountsResult countPadsRaw(const std::string& projectPath, const std::string& boardPath) {
    ensureGeneratorsRegistered();

    bool wxInitialized = _ensureWxInitialized();
    if (!wxInitialized) {
        return _fail("wxInitialize failed");
    }

    SETTINGS_MANAGER& settingsManager = Pgm().GetSettingsManager();
    wxString wxProjectPath = wxString::FromUTF8(projectPath);

    bool projectLoaded = settingsManager.LoadProject(wxProjectPath);
    if (!projectLoaded) {
        return _fail("LoadProject failed");
    }

    PROJECT* project = settingsManager.GetProject(wxProjectPath);
    if (!project) {
        return _fail("GetProject returned null");
    }

    // Bypass PCB_IO_MGR's format registry (which unconditionally links in every foreign-format
    // importer, per pcbnew/pcb_io/pcb_io_mgr.cpp's static REGISTER_PLUGIN globals) and go
    // straight to the one real KiCad-format plugin needed. This is still the exact same
    // LoadBoard() implementation PCB_IO_MGR would have dispatched to for KICAD_SEXP.
    PCB_IO_KICAD_SEXPR plugin;
    wxString wxBoardPath = wxString::FromUTF8(boardPath);
    std::unique_ptr<BOARD> board(plugin.LoadBoard(wxBoardPath, nullptr, nullptr, project));
    if (!board) {
        return _fail("LoadBoard failed");
    }

    PadCounts counts;
    counts.footprintCount = static_cast<std::int32_t>(board->Footprints().size());
    counts.trackCount = static_cast<std::int32_t>(board->Tracks().size());
    counts.zoneCount = static_cast<std::int32_t>(board->Zones().size());

    auto context = std::make_shared<HEADLESS_PCB_CONTEXT>(std::move(board), project, nullptr);
    if (!context->GetBoard()) {
        return _fail("HEADLESS_PCB_CONTEXT has no board");
    }

    API_HANDLER_PCB handler(context, nullptr);

    // Drive the query purely via protobuf -- exactly what the real API server does with a
    // message that arrived over the wire.
    kiapi::common::commands::GetItems getItems;
    getItems.mutable_header()->mutable_document()->set_type(kiapi::common::types::DocumentType::DOCTYPE_PCB);
    getItems.mutable_header()->mutable_document()->set_board_filename(
            wxFileName(wxBoardPath).GetFullName().ToStdString());
    getItems.add_types(kiapi::common::types::KOT_PCB_PAD);

    kiapi::common::ApiRequest request;
    request.mutable_header()->set_client_name("libkicad-smoketest");
    bool packed = request.mutable_message()->PackFrom(getItems);
    if (!packed) {
        return _fail("Failed to pack GetItems into request");
    }

    API_RESULT apiResult = handler.Handle(request);
    if (!apiResult.has_value()) {
        return _fail("Handle() failed: status=" + std::to_string(apiResult.error().status()) +
                      " message=" + apiResult.error().error_message());
    }

    kiapi::common::commands::GetItemsResponse itemsResponse;
    bool unpacked = apiResult.value().message().UnpackTo(&itemsResponse);
    if (!unpacked) {
        return _fail("Failed to unpack GetItemsResponse");
    }

    counts.padCount = static_cast<std::int32_t>(itemsResponse.items_size());

    RawPadCountsResult result;
    result.ok = true;
    result.counts = counts;
    return result;
}

} // namespace libkicad::detail
