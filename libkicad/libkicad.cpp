#include "libkicad_generators.hpp"
#include "libkicad_result.hpp"

#include <cstdint>
#include <memory>
#include <optional>
#include <utility>

// KiCad and wx headers aren't built against this project's strict warning settings and aren't
// ours to fix; silence their diagnostics for the includes and the rest of this file, since some
// of their inline/template bodies are only checked where we actually use them below.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"

#include <wx/app.h>
#include <wx/init.h>
#include <wx/filename.h>
#include <wx/tokenzr.h>

#include <pgm_base.h>
#include <settings/settings_manager.h>
#include <settings/color_settings.h>
#include <project.h>
#include <project/project_file.h>
#include <base_units.h>
#include <board.h>
#include <board_design_settings.h>
#include <footprint.h>
#include <pad.h>
#include <padstack.h>
#include <pcb_shape.h>
#include <pcb_track.h>
#include <zone.h>
#include <convert_shape_list_to_polygon.h>
#include <geometry/shape_poly_set.h>
#include <geometry/shape_line_chain.h>
#include <netinfo.h>
#include <netclass.h>
#include <project/net_settings.h>
#include <pcb_io/kicad_sexpr/pcb_io_kicad_sexpr.h>
#include <api/headless_pcb_context.h>
#include <api/api_handler_pcb.h>
#include <board_stackup_manager/board_stackup.h>
#include <board_stackup_manager/stackup_predefined_prms.h>

#include <api/common/commands/base_commands.pb.h>
#include <api/common/envelope.pb.h>
#include <api/common/types/base_types.pb.h>

#include <env_vars.h>

#include "step_export/exporter_step.h"
#include <reporter.h>

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

    // PATHS::GetStock3dmodelsPath() (used to default KICADn_3DMODEL_DIR, which 3D-model export
    // needs to resolve a footprint's linked STEP model) derives its answer from the *running
    // executable's own* bundle location -- fine for a real KiCad.app, wrong for this standalone
    // binary, which isn't inside any .app bundle. Setting the real value here, before InitPgm(),
    // makes COMMON_SETTINGS::InitializeEnvironment() see it as already defined externally (via
    // wxGetEnv) and leave it alone, the same way a real KiCad install's own env would. Mirrors
    // AppPaths.swift's resolveKicadCli() fallback -- the one other place this codebase already
    // assumes this install location when nothing else says otherwise.
    const wxString kFallbackKicadAppPath = wxT("/Applications/KiCad/KiCad.app");
    const wxString model3dDirVar = ENV_VAR::GetVersionedEnvVarName(wxT("3DMODEL_DIR"));
    wxString existingModel3dDir;
    if (!wxGetEnv(model3dDirVar, &existingModel3dDir) || existingModel3dDir.IsEmpty()) {
        const wxString candidate = kFallbackKicadAppPath + wxT("/Contents/SharedSupport/3dmodels");
        if (wxFileName::DirExists(candidate)) {
            wxSetEnv(model3dDirVar, candidate);
        }
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

RawNetNameResult _failNetName(std::string error) {
    RawNetNameResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawNetClassMembersResult _failNetClassMembers(std::string error) {
    RawNetClassMembersResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawPadsOnNetResult _failPadsOnNet(std::string error) {
    RawPadsOnNetResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawTracksOnNetResult _failTracksOnNet(std::string error) {
    RawTracksOnNetResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawZonesResult _failZones(std::string error) {
    RawZonesResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawBoardGeometryResult _failBoardGeometry(std::string error) {
    RawBoardGeometryResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawNonPlatedHolesResult _failNonPlatedHoles(std::string error) {
    RawNonPlatedHolesResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawPadResult _failPad(std::string error) {
    RawPadResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawStackupResult _failStackup(std::string error) {
    RawStackupResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawLayerColorsResult _failLayerColors(std::string error) {
    RawLayerColorsResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawStringListResult _failStringList(std::string error) {
    RawStringListResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawFootprintsResult _failFootprints(std::string error) {
    RawFootprintsResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawThroughHolesResult _failThroughHoles(std::string error) {
    RawThroughHolesResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

RawComponentModelExportResult _failComponentModelExport(std::string error) {
    RawComponentModelExportResult result;
    result.ok = false;
    result.error = std::move(error);
    return result;
}

// Keeps the BOARD alive (owned by the context) for as long as the caller needs it.
struct LoadedBoard {
    std::shared_ptr<HEADLESS_PCB_CONTEXT> context;
    BOARD* board = nullptr;
};

// Shared board-loading sequence: wx init, SETTINGS_MANAGER project load, PCB_IO_KICAD_SEXPR board
// load, HEADLESS_PCB_CONTEXT construction (this is what wires BOARD::SetProject(), needed before
// any netclass query -- see netsInNetClassRaw). Bypasses PCB_IO_MGR's format registry (which
// unconditionally links in every foreign-format importer, per pcbnew/pcb_io/pcb_io_mgr.cpp's
// static REGISTER_PLUGIN globals) and goes straight to the one real KiCad-format plugin needed;
// this is still the exact same LoadBoard() implementation PCB_IO_MGR would have dispatched to for
// KICAD_SEXP.
std::optional<LoadedBoard> _loadBoard(const std::string& projectPath, const std::string& boardPath,
                                       std::string& error) {
    bool wxInitialized = _ensureWxInitialized();
    if (!wxInitialized) {
        error = "wxInitialize failed";
        return std::nullopt;
    }

    SETTINGS_MANAGER& settingsManager = Pgm().GetSettingsManager();
    wxString wxProjectPath = wxString::FromUTF8(projectPath);

    bool projectLoaded = settingsManager.LoadProject(wxProjectPath);
    if (!projectLoaded) {
        error = "LoadProject failed";
        return std::nullopt;
    }

    PROJECT* project = settingsManager.GetProject(wxProjectPath);
    if (!project) {
        error = "GetProject returned null";
        return std::nullopt;
    }

    PCB_IO_KICAD_SEXPR plugin;
    wxString wxBoardPath = wxString::FromUTF8(boardPath);
    std::unique_ptr<BOARD> board(plugin.LoadBoard(wxBoardPath, nullptr, nullptr, project));
    if (!board) {
        error = "LoadBoard failed";
        return std::nullopt;
    }

    BOARD* boardPtr = board.get();
    auto context = std::make_shared<HEADLESS_PCB_CONTEXT>(std::move(board), project, nullptr);
    if (!context->GetBoard()) {
        error = "HEADLESS_PCB_CONTEXT has no board";
        return std::nullopt;
    }

    LoadedBoard result;
    result.context = std::move(context);
    result.board = boardPtr;
    return result;
}

// Finds one footprint's pad by number (e.g. "3"), falling back to a pin-function-name scan (e.g.
// "GND") if no pad matches by number -- those are different fields on PAD. Returns nullptr (with
// `error` set) if the footprint or pad/pin can't be found.
PAD* _findFootprintPad(BOARD* board, const std::string& footprintRef, const std::string& pin, std::string& error) {
    FOOTPRINT* footprint = board->FindFootprintByReference(wxString::FromUTF8(footprintRef));
    if (!footprint) {
        error = "footprint not found: " + footprintRef;
        return nullptr;
    }

    const wxString wxPin = wxString::FromUTF8(pin);
    PAD* pad = footprint->FindPadByNumber(wxPin);
    if (!pad) {
        for (PAD* candidate : footprint->Pads()) {
            if (candidate->GetPinFunction() == wxPin) {
                pad = candidate;
                break;
            }
        }
    }
    if (!pad) {
        error = "pad/pin not found: " + footprintRef + "." + pin;
        return nullptr;
    }
    return pad;
}

PolygonLoop _polygonLoop(const SHAPE_LINE_CHAIN& contour, bool hole, const VECTOR2I& auxOrigin) {
    PolygonLoop loop;
    loop.hole = hole;
    loop.pointsMm.reserve(static_cast<std::size_t>(contour.PointCount()));
    for (const VECTOR2I& point : contour.CPoints()) {
        const VECTOR2I relative = point - auxOrigin;
        loop.pointsMm.emplace_back(pcbIUScale.IUTomm(relative.x), -pcbIUScale.IUTomm(relative.y));
    }
    return loop;
}

template <typename AppendLoop>
void _forEachPolygonLoop(const SHAPE_POLY_SET& polygons, const VECTOR2I& auxOrigin, AppendLoop appendLoop) {
    for (int outlineIndex = 0; outlineIndex < polygons.OutlineCount(); ++outlineIndex) {
        const SHAPE_LINE_CHAIN& outline = polygons.COutline(outlineIndex);
        if (outline.PointCount() >= 3) {
            appendLoop(_polygonLoop(outline, false, auxOrigin));
        }
        for (int holeIndex = 0; holeIndex < polygons.HoleCount(outlineIndex); ++holeIndex) {
            const SHAPE_LINE_CHAIN& hole = polygons.CHole(outlineIndex, holeIndex);
            if (hole.PointCount() >= 3) {
                appendLoop(_polygonLoop(hole, true, auxOrigin));
            }
        }
    }
}

void _appendCopperPolygons(const SHAPE_POLY_SET& polygons, const VECTOR2I& auxOrigin,
                           const std::string& netName, const std::string& layerName,
                           std::vector<CopperPolygon>& destination) {
    _forEachPolygonLoop(polygons, auxOrigin, [&](PolygonLoop loop) {
        CopperPolygon polygon;
        polygon.netName = netName;
        polygon.copperLayerName = layerName;
        polygon.loop = std::move(loop);
        destination.push_back(std::move(polygon));
    });
}

} // namespace

RawPadCountsResult countPadsRaw(const std::string& projectPath, const std::string& boardPath) {
    ensureGeneratorsRegistered();

    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _fail(std::move(error));
    }
    BOARD* board = loaded->board;

    PadCounts counts;
    counts.footprintCount = static_cast<std::int32_t>(board->Footprints().size());
    counts.trackCount = static_cast<std::int32_t>(board->Tracks().size());
    counts.zoneCount = static_cast<std::int32_t>(board->Zones().size());

    API_HANDLER_PCB handler(loaded->context, nullptr);

    // Drive the query purely via protobuf -- exactly what the real API server does with a
    // message that arrived over the wire.
    kiapi::common::commands::GetItems getItems;
    getItems.mutable_header()->mutable_document()->set_type(kiapi::common::types::DocumentType::DOCTYPE_PCB);
    getItems.mutable_header()->mutable_document()->set_board_filename(
            wxFileName(wxString::FromUTF8(boardPath)).GetFullName().ToStdString());
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

RawNetNameResult netForFootprintPinRaw(const std::string& projectPath, const std::string& boardPath,
                                        const std::string& footprintRef, const std::string& pin) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failNetName(std::move(error));
    }
    BOARD* board = loaded->board;

    std::string findError;
    PAD* pad = _findFootprintPad(board, footprintRef, pin, findError);
    if (!pad) {
        return _failNetName(std::move(findError));
    }

    RawNetNameResult result;
    result.ok = true;
    result.netName = pad->GetNetname().ToStdString();
    return result;
}

RawPadResult resolvePinRaw(const std::string& projectPath, const std::string& boardPath,
                            const std::string& footprintRef, const std::string& pin) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failPad(std::move(error));
    }
    BOARD* board = loaded->board;

    std::string findError;
    PAD* pad = _findFootprintPad(board, footprintRef, pin, findError);
    if (!pad) {
        return _failPad(std::move(findError));
    }

    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();
    const VECTOR2I position = pad->GetPosition() - auxOrigin;

    RawPadResult result;
    result.ok = true;
    result.pad.footprintRef = footprintRef;
    result.pad.padNumber = pad->GetNumber().ToStdString();
    result.pad.netName = pad->GetNetname().ToStdString();
    result.pad.xMm = pcbIUScale.IUTomm(position.x);
    // KiCad's internal coordinate system has Y increasing downward; Gerber/pos.csv exports (and
    // this whole pipeline's own native frame, built entirely from those exports) have Y increasing
    // upward. kicad-cli's own exporters apply this flip internally; PAD::GetPosition() returns the
    // raw internal value, so it has to be negated here to land in the same frame as everything
    // else libkicad_query's callers consume. Confirmed empirically against a real board: a pad's
    // libkicad-reported Y was the exact negation of its Gerber-file Y at the same physical spot.
    result.pad.yMm = -pcbIUScale.IUTomm(position.y);
    result.pad.orientationDeg = pad->GetOrientation().AsDegrees();
    result.pad.copperLayerName = board->GetLayerName(pad->GetLayer()).ToStdString();
    result.pad.widthMm = pcbIUScale.IUTomm(pad->GetSizeX());
    result.pad.heightMm = pcbIUScale.IUTomm(pad->GetSizeY());
    return result;
}

RawNetClassMembersResult netsInNetClassRaw(const std::string& projectPath, const std::string& boardPath,
                                            const std::string& netClassName) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failNetClassMembers(std::move(error));
    }
    BOARD* board = loaded->board;

    // libkicad bypasses BOARD_LOADER (which normally calls this right after BOARD::SetProject()),
    // so every net's GetNetClass() would otherwise silently report the board's default "Default"
    // netclass rather than the project's real, user-defined ones.
    board->SynchronizeNetsAndNetClasses(/* aResetTrackAndViaSizes = */ false);

    RawNetClassMembersResult result;
    result.ok = true;
    const wxString wxNetClassName = wxString::FromUTF8(netClassName);
    for (NETINFO_ITEM* net : board->GetNetInfo()) {
        if (net->GetNetCode() == NETINFO_LIST::UNCONNECTED) {
            continue;
        }
        const NETCLASS* netClass = net->GetNetClass();
        // NETCLASS::GetName() can return a synthesized comma-joined name for aggregate/multi-
        // pattern netclasses -- ContainsNetclassWithName() is the purpose-built membership check.
        if (netClass != nullptr && netClass->ContainsNetclassWithName(wxNetClassName)) {
            result.netNames.push_back(net->GetNetname().ToStdString());
        }
    }
    return result;
}

RawPadsOnNetResult padsOnNetRaw(const std::string& projectPath, const std::string& boardPath,
                                 const std::string& netName) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failPadsOnNet(std::move(error));
    }
    BOARD* board = loaded->board;

    RawPadsOnNetResult result;
    result.ok = true;
    const wxString wxNetName = wxString::FromUTF8(netName);
    // gerber2ems's whole pipeline (Gerbers, drill file, pick&place CSV) is exported via kicad-cli
    // with --use-drill-file-origin, i.e. every coordinate it consumes is relative to the board's
    // configured auxiliary origin, not KiCad's absolute canvas origin. Subtract it here (in integer
    // KiCad internal units, before the mm conversion, to avoid floating-point precision loss) so
    // every PadPosition this function returns is already in that same frame.
    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();
    for (FOOTPRINT* footprint : board->Footprints()) {
        for (PAD* pad : footprint->Pads()) {
            if (pad->GetNetname() != wxNetName) {
                continue;
            }

            // PAD::GetPosition()/GetOrientation() already fold in the parent footprint's
            // placement/rotation transform -- no extra transform math needed here.
            const VECTOR2I position = pad->GetPosition() - auxOrigin;

            PadPosition padPosition;
            padPosition.footprintRef = footprint->GetReference().ToStdString();
            padPosition.padNumber = pad->GetNumber().ToStdString();
            padPosition.netName = netName;
            padPosition.xMm = pcbIUScale.IUTomm(position.x);
            // Y flip: see the identical comment in resolvePinRaw().
            padPosition.yMm = -pcbIUScale.IUTomm(position.y);
            padPosition.orientationDeg = pad->GetOrientation().AsDegrees();
            padPosition.copperLayerName = board->GetLayerName(pad->GetLayer()).ToStdString();
            padPosition.widthMm = pcbIUScale.IUTomm(pad->GetSizeX());
            padPosition.heightMm = pcbIUScale.IUTomm(pad->GetSizeY());
            result.pads.push_back(std::move(padPosition));
        }
    }
    return result;
}

RawTracksOnNetResult tracksOnNetRaw(const std::string& projectPath, const std::string& boardPath,
                                     const std::string& netName) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failTracksOnNet(std::move(error));
    }
    BOARD* board = loaded->board;

    RawTracksOnNetResult result;
    result.ok = true;
    const wxString wxNetName = wxString::FromUTF8(netName);
    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();
    for (PCB_TRACK* track : board->Tracks()) {
        // PCB_TRACE_T is the ordinary straight segment type. Vias have no propagation axis and
        // PCB_ARC_T would need a curved-port implementation rather than being approximated here.
        if (track->Type() != PCB_TRACE_T || track->GetNetname() != wxNetName) {
            continue;
        }
        const VECTOR2I start = track->GetStart() - auxOrigin;
        const VECTOR2I end = track->GetEnd() - auxOrigin;
        TrackSegment segment;
        segment.startXMm = pcbIUScale.IUTomm(start.x);
        segment.startYMm = -pcbIUScale.IUTomm(start.y);
        segment.endXMm = pcbIUScale.IUTomm(end.x);
        segment.endYMm = -pcbIUScale.IUTomm(end.y);
        segment.widthMm = pcbIUScale.IUTomm(track->GetWidth());
        segment.copperLayerName = board->GetLayerName(track->GetLayer()).ToStdString();
        result.tracks.push_back(std::move(segment));
    }
    return result;
}

RawPadsOnNetResult allPadsRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failPadsOnNet(std::move(error));
    }
    BOARD* board = loaded->board;

    RawPadsOnNetResult result;
    result.ok = true;
    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();
    for (FOOTPRINT* footprint : board->Footprints()) {
        for (PAD* pad : footprint->Pads()) {
            const VECTOR2I position = pad->GetPosition() - auxOrigin;
            PadPosition padPosition;
            padPosition.footprintRef = footprint->GetReference().ToStdString();
            padPosition.padNumber = pad->GetNumber().ToStdString();
            padPosition.netName = pad->GetNetname().ToStdString();
            padPosition.xMm = pcbIUScale.IUTomm(position.x);
            padPosition.yMm = -pcbIUScale.IUTomm(position.y);
            padPosition.orientationDeg = pad->GetOrientation().AsDegrees();
            padPosition.copperLayerName = board->GetLayerName(pad->GetLayer()).ToStdString();
            padPosition.widthMm = pcbIUScale.IUTomm(pad->GetSizeX());
            padPosition.heightMm = pcbIUScale.IUTomm(pad->GetSizeY());
            result.pads.push_back(std::move(padPosition));
        }
    }
    return result;
}

RawAllTracksResult allTracksRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        RawAllTracksResult result;
        result.ok = false;
        result.error = std::move(error);
        return result;
    }
    BOARD* board = loaded->board;

    RawAllTracksResult result;
    result.ok = true;
    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();
    for (PCB_TRACK* track : board->Tracks()) {
        if (track->Type() != PCB_TRACE_T) {
            continue; // see tracksOnNetRaw()'s own comment: vias/arcs excluded
        }
        const VECTOR2I start = track->GetStart() - auxOrigin;
        const VECTOR2I end = track->GetEnd() - auxOrigin;
        TrackSegment segment;
        segment.startXMm = pcbIUScale.IUTomm(start.x);
        segment.startYMm = -pcbIUScale.IUTomm(start.y);
        segment.endXMm = pcbIUScale.IUTomm(end.x);
        segment.endYMm = -pcbIUScale.IUTomm(end.y);
        segment.widthMm = pcbIUScale.IUTomm(track->GetWidth());
        segment.copperLayerName = board->GetLayerName(track->GetLayer()).ToStdString();
        result.tracks.emplace_back(track->GetNetname().ToStdString(), std::move(segment));
    }
    return result;
}

RawZonesResult zonesRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failZones(std::move(error));
    }
    BOARD* board = loaded->board;

    RawZonesResult result;
    result.ok = true;
    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();
    for (ZONE* zone : board->Zones()) {
        const SHAPE_POLY_SET* outline = zone->Outline();
        if (outline == nullptr) {
            continue;
        }
        // Every copper layer this zone is actually filled/assigned on -- a zone typically shares one
        // drawn outline across every one of them (see ZoneInfo's own doc comment for why the raw
        // outline, not the real per-layer filled shape, is what's returned).
        for (PCB_LAYER_ID layer : zone->GetLayerSet().CuStack()) {
            // Every disjoint outer contour (an island of the pour) -- any cutouts drawn inside one
            // are deliberately not subtracted (see ZoneInfo's own doc comment: conservative, not
            // exact).
            for (int outlineIndex = 0; outlineIndex < outline->OutlineCount(); ++outlineIndex) {
                const SHAPE_LINE_CHAIN& contour = outline->Outline(outlineIndex);
                if (contour.PointCount() < 3) {
                    continue;
                }
                ZoneInfo zoneInfo;
                zoneInfo.netName = zone->GetNetname().ToStdString();
                zoneInfo.copperLayerName = board->GetLayerName(layer).ToStdString();
                zoneInfo.outlineMm.reserve(static_cast<std::size_t>(contour.PointCount()));
                for (const VECTOR2I& point : contour.CPoints()) {
                    const VECTOR2I relative = point - auxOrigin;
                    // Y flip: see the identical comment in resolvePinRaw().
                    zoneInfo.outlineMm.emplace_back(pcbIUScale.IUTomm(relative.x), -pcbIUScale.IUTomm(relative.y));
                }
                result.zones.push_back(std::move(zoneInfo));
            }
        }
    }
    return result;
}

RawBoardGeometryResult boardGeometryRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failBoardGeometry(std::move(error));
    }
    BOARD* board = loaded->board;
    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();
    const int maxError = board->GetDesignSettings().m_MaxError;

    RawBoardGeometryResult result;
    result.ok = true;

    SHAPE_POLY_SET boardOutline;
    if (!board->GetBoardPolygonOutlines(boardOutline, false, nullptr, false, false)) {
        // KiCad's Gerber plotter permits open Edge.Cuts graphics, and footprints sometimes carry
        // such graphics for board-edge markings or mechanical guidance.  Unfortunately,
        // GetBoardPolygonOutlines() rejects the entire board when even one of those footprint
        // graphics is open, despite a valid closed board-owned outline being present.  Retry with
        // the board drawings alone in that case.  This retains KiCad's own curve tessellation,
        // chaining tolerance, contour nesting, and cutout handling without inventing a bounding
        // box or accepting an actually open main outline.
        std::vector<PCB_SHAPE*> boardEdgeShapes;
        for (BOARD_ITEM* drawing : board->Drawings()) {
            if (!PCB_SHAPE::ClassOf(drawing)) {
                continue;
            }
            PCB_SHAPE* shape = static_cast<PCB_SHAPE*>(drawing);
            if (shape->GetLayer() == Edge_Cuts) {
                boardEdgeShapes.push_back(shape);
            }
        }

        boardOutline.RemoveAllContours();
        if (boardEdgeShapes.empty() ||
            !ConvertOutlineToPolygon(boardEdgeShapes, boardOutline, maxError, board->GetOutlinesChainingEpsilon(),
                                     true, nullptr, false)) {
            return _failBoardGeometry("Board Edge.Cuts do not form valid closed polygons");
        }
    }
    _forEachPolygonLoop(boardOutline, auxOrigin,
                        [&](PolygonLoop loop) { result.geometry.outline.push_back(std::move(loop)); });
    if (result.geometry.outline.empty()) {
        return _failBoardGeometry("Board has no closed Edge.Cuts outline");
    }

    for (PCB_LAYER_ID layer : board->GetEnabledLayers().CuStack()) {
        const std::string layerName = board->GetLayerName(layer).ToStdString();

        for (PCB_TRACK* track : board->Tracks()) {
            if (!track->IsOnLayer(layer)) {
                continue;
            }
            SHAPE_POLY_SET polygons;
            track->TransformShapeToPolygon(polygons, layer, 0, maxError, ERROR_INSIDE);
            _appendCopperPolygons(polygons, auxOrigin, track->GetNetname().ToStdString(), layerName,
                                  result.geometry.copper);
        }

        for (FOOTPRINT* footprint : board->Footprints()) {
            for (PAD* pad : footprint->Pads()) {
                if (!pad->FlashLayer(layer)) {
                    continue;
                }
                SHAPE_POLY_SET polygons;
                pad->TransformShapeToPolygon(polygons, layer, 0, maxError, ERROR_INSIDE);
                _appendCopperPolygons(polygons, auxOrigin, pad->GetNetname().ToStdString(), layerName,
                                      result.geometry.copper);
            }
            for (ZONE* zone : footprint->Zones()) {
                if (!zone->GetLayerSet().Contains(layer)) {
                    continue;
                }
                SHAPE_POLY_SET polygons;
                zone->TransformSolidAreasShapesToPolygon(layer, polygons);
                _appendCopperPolygons(polygons, auxOrigin, zone->GetNetname().ToStdString(), layerName,
                                      result.geometry.copper);
            }
        }

        for (ZONE* zone : board->Zones()) {
            if (!zone->GetLayerSet().Contains(layer)) {
                continue;
            }
            SHAPE_POLY_SET polygons;
            zone->TransformSolidAreasShapesToPolygon(layer, polygons);
            _appendCopperPolygons(polygons, auxOrigin, zone->GetNetname().ToStdString(), layerName,
                                  result.geometry.copper);
        }
    }

    SHAPE_POLY_SET frontMask;
    board->ConvertBrdLayerToPolygonalContours(F_Mask, frontMask);
    _forEachPolygonLoop(frontMask, auxOrigin, [&](PolygonLoop loop) {
        result.geometry.frontMaskOpenings.push_back(std::move(loop));
    });

    SHAPE_POLY_SET backMask;
    board->ConvertBrdLayerToPolygonalContours(B_Mask, backMask);
    _forEachPolygonLoop(backMask, auxOrigin, [&](PolygonLoop loop) {
        result.geometry.backMaskOpenings.push_back(std::move(loop));
    });

    return result;
}

RawStackupResult stackupRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failStackup(std::move(error));
    }
    BOARD* board = loaded->board;

    RawStackupResult result;
    result.ok = true;
    const BOARD_STACKUP& stackup = board->GetDesignSettings().GetStackupDescriptor();
    for (const BOARD_STACKUP_ITEM* item : stackup.GetList()) {
        if (!item->IsEnabled()) {
            continue;
        }
        StackupLayer layer;
        if (item->GetType() == BS_ITEM_TYPE_COPPER) {
            // BOARD_STACKUP_ITEM::GetLayerName() is never actually populated by the file parser
            // (only SetBrdLayerId()/SetDielectricLayerId() are, confirmed by reading
            // pcb_io_kicad_sexpr_parser.cpp's parseBoardStackup()) -- the board's own layer table,
            // keyed by the copper layer id, is the real source of the "F.Cu"/"In1.Cu"/"B.Cu" names
            // gerber file matching needs. Same lookup padsOnNetRaw/resolvePinRaw already use for a
            // pad's copper layer.
            layer.kind = StackupLayerKind::Copper;
            layer.name = board->GetLayerName(item->GetBrdLayerId()).ToStdString();
            layer.thicknessMm = pcbIUScale.IUTomm(item->GetThickness());
        } else if (item->GetType() == BS_ITEM_TYPE_DIELECTRIC) {
            layer.kind = item->GetTypeName() == KEY_CORE ? StackupLayerKind::Core : StackupLayerKind::Prepreg;
            // Dielectric layers have no PCB_LAYER_ID (GetBrdLayerId() is UNDEFINED_LAYER) and, like
            // GetLayerName() above, no name of their own in the file -- only a 1-based top-to-bottom
            // index (GetDielectricLayerId()). Synthesize the same "Dielectric N" label the
            // hand-maintained stackup.json this replaces already used, purely for
            // Simulation::addDumpBoxes()'s dump-box filenames -- nothing keys lookups off it.
            layer.name = "Dielectric " + std::to_string(item->GetDielectricLayerId());
            layer.thicknessMm = pcbIUScale.IUTomm(item->GetThickness());
            layer.epsilonR = item->GetEpsilonR();
            layer.lossTangent = item->GetLossTangent();
        } else if (item->GetType() == BS_ITEM_TYPE_SOLDERMASK) {
            // Only one BS_ITEM_TYPE_SOLDERMASK enum value exists -- top vs. bottom is distinguished
            // by which copper layer this item's own GetBrdLayerId() sits alongside, exactly like the
            // BS_ITEM_TYPE_COPPER branch above. GetEpsilonR()/GetLossTangent()/GetThickness() are
            // all valid for solder mask items (confirmed against KiCad's own board_stackup.cpp, not
            // just documentation) and already default to sensible real-world values (ε_r=3.3,
            // thickness=0.01mm, loss tangent=0.0) even for a board whose stackup was never opened in
            // KiCad's own stackup editor, so no extra fallback is needed here.
            layer.kind = item->GetBrdLayerId() == F_Mask ? StackupLayerKind::SolderMaskTop
                                                            : StackupLayerKind::SolderMaskBottom;
            layer.name = board->GetLayerName(item->GetBrdLayerId()).ToStdString();
            layer.thicknessMm = pcbIUScale.IUTomm(item->GetThickness());
            layer.epsilonR = item->GetEpsilonR();
            layer.lossTangent = item->GetLossTangent();
        } else {
            // Paste/silkscreen -- not part of the layer stack a field simulation cares about.
            continue;
        }
        result.layers.push_back(std::move(layer));
    }
    return result;
}

RawLayerColorsResult layerColorsRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failLayerColors(std::move(error));
    }
    BOARD* board = loaded->board;

    // Empty name resolves to KiCad's own default color settings if no other theme is found/active
    // for this (headless, GUI-less) process -- see GetColorSettings()'s own doc comment. This is
    // the same COLOR_SETTINGS machinery the real PCB editor's "Appearance" panel reads from, just
    // with no per-project theme selection available outside a full GUI session to prefer instead.
    COLOR_SETTINGS* colorSettings = Pgm().GetSettingsManager().GetColorSettings(wxEmptyString);
    if (colorSettings == nullptr) {
        return _failLayerColors("No PCB color theme available");
    }

    RawLayerColorsResult result;
    result.ok = true;
    const BOARD_STACKUP& stackup = board->GetDesignSettings().GetStackupDescriptor();
    for (const BOARD_STACKUP_ITEM* item : stackup.GetList()) {
        if (!item->IsEnabled() || item->GetType() != BS_ITEM_TYPE_COPPER) {
            continue;
        }
        LayerColor layerColor;
        layerColor.name = board->GetLayerName(item->GetBrdLayerId()).ToStdString();
        layerColor.hex = colorSettings->GetColor(item->GetBrdLayerId()).ToHexString().ToStdString();
        result.colors.push_back(std::move(layerColor));
    }
    return result;
}

RawStringListResult netClassesRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failStringList(std::move(error));
    }
    PROJECT* project = loaded->board->GetProject();
    if (project == nullptr) {
        return _failStringList("Board has no linked project -- net classes require a sibling .kicad_pro");
    }

    RawStringListResult result;
    result.ok = true;
    // Every user-defined net class, independent of whether a net currently uses it -- matches what
    // KiCad's own Net Classes editor shows, unlike netsInNetClassRaw (which only cares about
    // classes actually assigned to a net it's checking membership for).
    for (const auto& [name, netclass] : project->GetProjectFile().NetSettings()->GetNetclasses()) {
        result.values.push_back(name.ToStdString());
    }
    return result;
}

RawStringListResult allNetsRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failStringList(std::move(error));
    }
    BOARD* board = loaded->board;

    RawStringListResult result;
    result.ok = true;
    for (NETINFO_ITEM* net : board->GetNetInfo()) {
        if (net->GetNetCode() == NETINFO_LIST::UNCONNECTED) {
            continue;
        }
        result.values.push_back(net->GetNetname().ToStdString());
    }
    return result;
}

RawFootprintsResult footprintsRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failFootprints(std::move(error));
    }
    BOARD* board = loaded->board;

    RawFootprintsResult result;
    result.ok = true;
    for (FOOTPRINT* footprint : board->Footprints()) {
        FootprintInfo info;
        info.reference = footprint->GetReference().ToStdString();
        info.value = footprint->GetValue().ToStdString();
        for (PAD* pad : footprint->Pads()) {
            // A pad with no number is KiCad's own convention for a non-electrical pad -- most
            // commonly a paste-only "aperture" pad some SMD footprints (e.g. Capacitor_SMD's own
            // 0201/0402-class parts) include purely to shape the solder-paste stencil opening, never
            // assigned a net or a schematic pin mapping. Counting these here inflated a genuine 2-pin
            // part's own pin count to 4, which silently disqualified it from
            // port_resolution.cpp's _resolveLumpedComponents() (which only auto-discovers exactly
            // 2-pin R/L/C components) -- confirmed on a real board where two coupling capacitors
            // using this exact footprint were never detected because of it.
            if (pad->GetNumber().IsEmpty()) {
                continue;
            }
            FootprintPin pin;
            pin.number = pad->GetNumber().ToStdString();
            pin.function = pad->GetPinFunction().ToStdString();
            pin.netName = pad->GetNetname().ToStdString();
            info.pins.push_back(std::move(pin));
        }
        result.footprints.push_back(std::move(info));
    }
    return result;
}

RawThroughHolesResult throughHolesRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failThroughHoles(std::move(error));
    }
    BOARD* board = loaded->board;

    RawThroughHolesResult result;
    result.ok = true;
    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();

    // Plain KiCad vias -- not tied to any footprint, always round (GetWidth() is the annular ring's
    // own diameter, GetDrillValue() the hole's -- both single values, unlike a pad's separate X/Y).
    for (PCB_TRACK* track : board->Tracks()) {
        if (track->Type() != PCB_VIA_T) {
            continue;
        }
        PCB_VIA* via = static_cast<PCB_VIA*>(track);
        const VECTOR2I position = via->GetPosition() - auxOrigin;

        ThroughHole hole;
        hole.xMm = pcbIUScale.IUTomm(position.x);
        // Y flip: see the identical comment in resolvePinRaw().
        hole.yMm = -pcbIUScale.IUTomm(position.y);
        hole.netName = via->GetNetname().ToStdString();
        const double widthMm = pcbIUScale.IUTomm(via->GetWidth());
        hole.padWidthMm = widthMm;
        hole.padHeightMm = widthMm;
        const double drillMm = pcbIUScale.IUTomm(via->GetDrillValue());
        hole.drillWidthMm = drillMm;
        hole.drillHeightMm = drillMm;
        result.holes.push_back(std::move(hole));
    }

    // Through-hole pads (PAD_ATTRIB::PTH) -- e.g. a connector's SHIELD pin -- which can be oblong
    // (GetSizeX()/GetSizeY() and GetDrillSizeX()/GetDrillSizeY() genuinely differ), unlike a via.
    // NPTH pads are deliberately excluded: those have no copper at all (see ThroughHole's own doc
    // comment), a different feature entirely (gerber2ems::NPTHHole/getNPTHHoles()).
    for (FOOTPRINT* footprint : board->Footprints()) {
        for (PAD* pad : footprint->Pads()) {
            if (pad->GetAttribute() != PAD_ATTRIB::PTH) {
                continue;
            }
            const VECTOR2I position = pad->GetPosition() - auxOrigin;

            ThroughHole hole;
            hole.xMm = pcbIUScale.IUTomm(position.x);
            // Y flip: see the identical comment in resolvePinRaw().
            hole.yMm = -pcbIUScale.IUTomm(position.y);
            hole.netName = pad->GetNetname().ToStdString();
            hole.footprintRef = footprint->GetReference().ToStdString();
            hole.padNumber = pad->GetNumber().ToStdString();
            hole.padWidthMm = pcbIUScale.IUTomm(pad->GetSizeX());
            hole.padHeightMm = pcbIUScale.IUTomm(pad->GetSizeY());
            hole.drillWidthMm = pcbIUScale.IUTomm(pad->GetDrillSizeX());
            hole.drillHeightMm = pcbIUScale.IUTomm(pad->GetDrillSizeY());
            hole.orientationDeg = pad->GetOrientation().AsDegrees();
            result.holes.push_back(std::move(hole));
        }
    }

    return result;
}

RawNonPlatedHolesResult nonPlatedHolesRaw(const std::string& projectPath, const std::string& boardPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failNonPlatedHoles(std::move(error));
    }
    BOARD* board = loaded->board;

    RawNonPlatedHolesResult result;
    result.ok = true;
    const VECTOR2I auxOrigin = board->GetDesignSettings().GetAuxOrigin();
    for (FOOTPRINT* footprint : board->Footprints()) {
        for (PAD* pad : footprint->Pads()) {
            if (pad->GetAttribute() != PAD_ATTRIB::NPTH) {
                continue;
            }
            const VECTOR2I position = pad->GetPosition() - auxOrigin;
            NonPlatedHole hole;
            hole.xMm = pcbIUScale.IUTomm(position.x);
            hole.yMm = -pcbIUScale.IUTomm(position.y);
            hole.drillWidthMm = pcbIUScale.IUTomm(pad->GetDrillSizeX());
            hole.drillHeightMm = pcbIUScale.IUTomm(pad->GetDrillSizeY());
            hole.orientationDeg = pad->GetOrientation().AsDegrees();
            result.holes.push_back(std::move(hole));
        }
    }
    return result;
}

RawComponentModelExportResult exportComponentModelsRaw(const std::string& projectPath, const std::string& boardPath,
                                                          const std::string& componentFilter,
                                                          const std::string& outputStlPath) {
    std::string error;
    std::optional<LoadedBoard> loaded = _loadBoard(projectPath, boardPath, error);
    if (!loaded) {
        return _failComponentModelExport(std::move(error));
    }
    BOARD* board = loaded->board;

    EXPORTER_STEP_PARAMS params;
    params.m_Format = EXPORTER_STEP_PARAMS::FORMAT::STL;
    params.m_ComponentFilter = wxString::FromUTF8(componentFilter);
    params.m_BoardOnly = false;
    params.m_ExportBoardBody = false;
    params.m_ExportComponents = true;
    params.m_UseDrillOrigin = true;
    params.m_Overwrite = true;

    WX_STRING_REPORTER reporter;
    EXPORTER_STEP exporter(board, params, &reporter);
    // Not set by the constructor -- see EXPORTER_STEP's own header and KiCad's own CLI reference
    // usage (pcbnew_jobs_handler.cpp), which sets this the same way after construction. Export()
    // still needs *a* real output path even though the STL it writes here is no longer read back by
    // any caller (GetComponentTriangles() below returns the same mesh directly, plus real color --
    // see its own doc comment) -- Export() is what actually builds the shapes into m_pcbModel in
    // the first place, regardless of which format it's asked to write; the STL file itself is kept
    // purely as an incidental, harmless-to-ignore debug artifact.
    exporter.m_outputFile = wxString::FromUTF8(outputStlPath);
    const bool exportOk = exporter.Export();

    RawComponentModelExportResult result;
    result.ok = true; // the query itself succeeded even if the exporter reported per-component issues
    result.result.exportSucceeded = exportOk;

    wxStringTokenizer tokenizer(reporter.GetMessages(), wxT("\n"));
    while (tokenizer.HasMoreTokens()) {
        wxString line = tokenizer.GetNextToken();
        if (!line.IsEmpty()) {
            result.result.messages.push_back(line.ToStdString());
        }
    }

    if (exportOk) {
        std::vector<STEP_COMPONENT_TRIANGLE> rawTriangles;
        exporter.GetComponentTriangles(rawTriangles);
        result.result.triangles.reserve(rawTriangles.size());
        for (const STEP_COMPONENT_TRIANGLE& t : rawTriangles) {
            result.result.triangles.push_back(ComponentTriangle{
                    t.ax, t.ay, t.az, t.bx, t.by, t.bz, t.cx, t.cy, t.cz, t.r, t.g, t.b, t.a});
        }
        result.result.topCopperZMm = exporter.GetTopCopperZ();
    }

    return result;
}

} // namespace libkicad::detail
