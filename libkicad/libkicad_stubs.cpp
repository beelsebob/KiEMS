// Link-time stub definitions for the small slice of KiCad's GUI/tool-framework surface that
// api_handler_pcb.cpp / api_handler_board.cpp / pcb_context.cpp reference from handler methods
// and sibling classes we never exercise from this headless smoketest (RefillZones, netlist
// import, selection, the 3D viewer, PCB_EDIT_FRAME_CONTEXT, ...). These object files are single
// translation units mixing headless-safe code with GUI-only code, so linking the parts we need
// (HEADLESS_PCB_CONTEXT + API_HANDLER_PCB::Handle(GetItems)) pulls in symbol references from the
// parts we don't. None of the bodies below are ever reached by the GetItems path; they exist
// purely so the linker can resolve real KiCad class members without us having to compile the
// full (wx/GAL/3D-viewer-dependent) pcbnew GUI kiface.
#include <cstdlib>
#include <cstdio>

#include <board_loader.h>
#include <pcb_edit_frame.h>
#include <netlist_reader/board_netlist_updater.h>
#include <netlist_reader/pcb_netlist_utils.h>
#include <tools/pcb_selection_tool.h>
#include <project_pcb.h>
#include <3d_cache/3d_cache.h>
#include <pcb_base_frame.h>
#include <3d_viewer/eda_3d_viewer_frame.h>
#include <3d_viewer/eda_3d_viewer_settings.h>
#include <navlib/nl_pcbnew_plugin.h>
#include <navlib/nl_pcbnew_plugin_impl.h>
#include <3d_navlib/nl_3d_viewer_plugin.h>
#include <zone_filler.h>
#include <footprint_library_adapter.h>
#include <tools/zone_filler_tool.h>
#include <tools/drc_tool.h>
#include <drc/rule_editor/drc_re_rule_loader.h>
#include <widgets/appearance_controls.h>
#include <autorouter/spread_footprints.h>
#include <string_utils.h>
#include <kiface_base.h>

namespace
{
// Uses abort() rather than throwing: several of the classes stubbed below have members with no
// default constructor (unique_ptr<T> for a forward-declared-only T, reference members, ...), and
// a throwing constructor body would require the compiler to emit exception-unwinding cleanup for
// those already-constructed members -- which in turn requires T to be a complete type we don't
// actually have. None of these bodies are ever reached by the GetItems smoketest path, so an
// abrupt abort() is fine and keeps the stubs simple.
// noexcept matters here, not just abort(): without it the compiler must assume this call can
// exit via a C++ exception, which forces it to generate unwind-cleanup for already-constructed
// members of the calling constructor (e.g. NL_PCBNEW_PLUGIN's unique_ptr<NL_PCBNEW_PLUGIN_IMPL>),
// which in turn requires the pointee to be a complete type we don't have (its real definition
// needs a proprietary 3Dconnexion SDK header). noexcept tells it that path is unreachable.
[[noreturn]] void notImplemented( const char* what ) noexcept
{
    std::fprintf( stderr, "libkicad stub: %s is not implemented in the headless smoketest\n", what );
    std::abort();
}
} // namespace

// -- board_loader.h ----------------------------------------------------------------------------
// Real definition lives in board_loader.cpp, which we don't link (it would pull in the full
// PCB_IO_MGR format-plugin registry via pcb_io_mgr.cpp's static REGISTER_PLUGIN globals).
bool BOARD_LOADER::SaveBoard( wxString&, BOARD*, PCB_IO_MGR::PCB_FILE_T )
{
    notImplemented( "BOARD_LOADER::SaveBoard" );
}

bool BOARD_LOADER::SaveBoard( wxString&, BOARD* )
{
    notImplemented( "BOARD_LOADER::SaveBoard" );
}

// -- pcb_edit_frame.h (only referenced via PCB_EDIT_FRAME_CONTEXT, never constructed here) ------
void PCB_EDIT_FRAME::UpdateUserInterface()
{
}

void PCB_EDIT_FRAME::LoadDrawingSheet()
{
}

bool PCB_EDIT_FRAME::SaveBoard( bool, bool )
{
    notImplemented( "PCB_EDIT_FRAME::SaveBoard" );
}

bool PCB_EDIT_FRAME::SavePcbCopy( const wxString&, bool, bool )
{
    notImplemented( "PCB_EDIT_FRAME::SavePcbCopy" );
}

void PCB_EDIT_FRAME::OnNetlistChanged( BOARD_NETLIST_UPDATER&, bool* )
{
}

bool PCB_EDIT_FRAME::ReadNetlistFromFile( const wxString&, NETLIST&, REPORTER& )
{
    notImplemented( "PCB_EDIT_FRAME::ReadNetlistFromFile" );
}

// -- board_netlist_updater.h -------------------------------------------------------------------
BOARD_NETLIST_UPDATER::BOARD_NETLIST_UPDATER( PCB_EDIT_FRAME* aFrame, BOARD* ) : m_commit( aFrame )
{
    notImplemented( "BOARD_NETLIST_UPDATER::BOARD_NETLIST_UPDATER(PCB_EDIT_FRAME*, BOARD*)" );
}

BOARD_NETLIST_UPDATER::BOARD_NETLIST_UPDATER( TOOL_MANAGER* aToolManager, BOARD* ) :
        m_commit( aToolManager )
{
    notImplemented( "BOARD_NETLIST_UPDATER::BOARD_NETLIST_UPDATER(TOOL_MANAGER*, BOARD*)" );
}

BOARD_NETLIST_UPDATER::~BOARD_NETLIST_UPDATER()
{
}

bool BOARD_NETLIST_UPDATER::UpdateNetlist( NETLIST& )
{
    notImplemented( "BOARD_NETLIST_UPDATER::UpdateNetlist" );
}

void LoadNetlistFootprints( BOARD*, NETLIST&, REPORTER& )
{
    notImplemented( "LoadNetlistFootprints" );
}

// -- pcb_selection_tool.h ------------------------------------------------------------------------
bool PCB_SELECTION_TOOL::Init()
{
    return false;
}

PCB_SELECTION& PCB_SELECTION_TOOL::GetSelection()
{
    notImplemented( "PCB_SELECTION_TOOL::GetSelection" );
}

void PCB_SELECTION_TOOL::RebuildSelection()
{
}

// -- project_pcb.h / 3d_cache.h -------------------------------------------------------------------
S3D_CACHE::S3D_CACHE()
{
}

S3D_CACHE::~S3D_CACHE()
{
}

bool S3D_CACHE::Set3DConfigDir( const wxString& )
{
    return false;
}

bool S3D_CACHE::SetProject( PROJECT* )
{
    return false;
}

void S3D_CACHE::SetProgramBase( PGM_BASE* )
{
}

FILENAME_RESOLVER* S3D_CACHE::GetResolver() noexcept
{
    return nullptr;
}

void S3D_CACHE::CleanCacheDir( int )
{
}

// -- pcb_base_frame.h / 3d_viewer -----------------------------------------------------------------
// PCB_BASE_FRAME::CreateAndShow3D_Frame/Update3DView/Get3DViewerFrame (defined in pcb_base_frame.cpp,
// which we don't build) construct and drive a real EDA_3D_VIEWER_FRAME. Turns out unavoidable: some
// other pcbcommon.a member (pcb_viewer_tools.cpp, an interactive tool unrelated to GetItems) also
// needs PCB_BASE_FRAME::CreateAndShow3D_Frame, which forces pcb_base_frame.cpp.o into the link
// regardless, so its downstream 3D-viewer/SpaceMouse-navigation classes need real (if trivial)
// definitions too.
void PCB_BASE_FRAME::SetDisplayOptions( const PCB_DISPLAY_OPTIONS&, bool )
{
}

PCBNEW_SETTINGS* PCB_BASE_FRAME::GetPcbNewSettings() const
{
    return nullptr;
}

EDA_3D_VIEWER_FRAME::EDA_3D_VIEWER_FRAME( KIWAY* aKiway, PCB_BASE_FRAME* aParent,
                                           const wxString& aTitle, long aStyle ) :
        KIWAY_PLAYER( aKiway, aParent, FRAME_PCB_DISPLAY3D, aTitle, wxDefaultPosition,
                      wxDefaultSize, aStyle, wxT( "Ki3DViewLibkicadStub" ), pcbIUScale ),
        m_currentCamera( m_trackBallCamera ),
        m_trackBallCamera( 100.0f )
{
    notImplemented( "EDA_3D_VIEWER_FRAME::EDA_3D_VIEWER_FRAME" );
}

EDA_3D_VIEWER_FRAME::~EDA_3D_VIEWER_FRAME()
{
}

void EDA_3D_VIEWER_FRAME::ReloadRequest()
{
}

void EDA_3D_VIEWER_FRAME::Redraw()
{
}

EDA_3D_VIEWER_SETTINGS::EDA_3D_VIEWER_SETTINGS() : APP_SETTINGS_BASE( "3d_viewer_libkicad_stub", 0 )
{
}

bool EDA_3D_VIEWER_SETTINGS::MigrateFromLegacy( wxConfigBase* )
{
    return false;
}

NL_PCBNEW_PLUGIN::NL_PCBNEW_PLUGIN( PCB_DRAW_PANEL_GAL* )
{
    notImplemented( "NL_PCBNEW_PLUGIN::NL_PCBNEW_PLUGIN" );
}

void NL_PCBNEW_PLUGIN::SetFocus( bool )
{
}

// -- footprint_library_adapter.h -----------------------------------------------------------------
// PROJECT_PCB (project_pcb.cpp, which we need for the S3D_CACHE accessors above) constructs one of
// these; its real definition lives in footprint_library_adapter.cpp, which we don't build, and
// pulling it in would in turn need PCB_IO_MGR's full format-plugin registry (pcb_io_mgr.cpp's
// static REGISTER_PLUGIN globals unconditionally reference all 15 foreign CAD importers -- see the
// comment on BOARD_LOADER::SaveBoard above). Stubbing just this constructor/destructor avoids that
// whole branch.
FOOTPRINT_LIBRARY_ADAPTER::FOOTPRINT_LIBRARY_ADAPTER( LIBRARY_MANAGER& aManager ) :
        LIBRARY_MANAGER_ADAPTER( aManager )
{
}

FOOTPRINT_LIBRARY_ADAPTER::~FOOTPRINT_LIBRARY_ADAPTER()
{
}

// -- zone_filler.h / zone_filler_tool.h -------------------------------------------------------------
ZONE_FILLER::ZONE_FILLER( BOARD*, COMMIT* )
{
    notImplemented( "ZONE_FILLER::ZONE_FILLER" );
}

ZONE_FILLER::~ZONE_FILLER()
{
}

bool ZONE_FILLER::Fill( const std::vector<ZONE*>&, bool, wxWindow* )
{
    notImplemented( "ZONE_FILLER::Fill" );
}

ZONE_FILLER_TOOL::ZONE_FILLER_TOOL() : PCB_TOOL_BASE( "libkicad.stub.zoneFillerTool" )
{
}

ZONE_FILLER_TOOL::~ZONE_FILLER_TOOL()
{
}

void ZONE_FILLER_TOOL::FillAllZones( wxWindow*, PROGRESS_REPORTER*, bool )
{
    notImplemented( "ZONE_FILLER_TOOL::FillAllZones" );
}

void ZONE_FILLER_TOOL::PostFillRefresh( bool )
{
}

void ZONE_FILLER_TOOL::Reset( TOOL_BASE::RESET_REASON )
{
}

void ZONE_FILLER_TOOL::setTransitions()
{
}

// -- tools/pcb_tool_base.h / tools/drc_tool.h --------------------------------------------------
bool PCB_TOOL_BASE::Init()
{
    return false;
}

void PCB_TOOL_BASE::Reset( TOOL_BASE::RESET_REASON )
{
}

void PCB_TOOL_BASE::setTransitions()
{
}

bool PCB_TOOL_BASE::Is45Limited() const
{
    return false;
}

bool PCB_TOOL_BASE::Is90Limited() const
{
    return false;
}

DRC_TOOL::DRC_TOOL() : PCB_TOOL_BASE( "libkicad.stub.drcTool" )
{
}

DRC_TOOL::~DRC_TOOL()
{
}

void DRC_TOOL::Reset( TOOL_BASE::RESET_REASON )
{
}

void DRC_TOOL::setTransitions()
{
}

// -- drc/rule_editor/drc_re_rule_loader.h -------------------------------------------------------
wxString DRC_RULE_LOADER::ExtractRuleText( const wxString&, const wxString& )
{
    return wxEmptyString;
}

wxString DRC_RULE_LOADER::ExtractRuleComment( const wxString& )
{
    return wxEmptyString;
}

// -- widgets/appearance_controls.h ---------------------------------------------------------------
void APPEARANCE_CONTROLS::OnBoardChanged()
{
}

// -- autorouter/spread_footprints.h --------------------------------------------------------------
void SpreadFootprints( std::vector<FOOTPRINT*>*, VECTOR2I, bool, int, int )
{
    notImplemented( "SpreadFootprints" );
}

// -- string_utils.h ---------------------------------------------------------------------------
void ConvertMarkdown2Html( const wxString&, wxString& aHtmlOutput )
{
    aHtmlOutput = wxEmptyString;
}

// -- kiface_base.h ------------------------------------------------------------------------------
namespace
{
class LIBKICAD_STUB_KIFACE : public KIFACE_BASE
{
public:
    LIBKICAD_STUB_KIFACE() : KIFACE_BASE( "libkicad-stub", KIWAY::FACE_PCB ) {}

    bool OnKifaceStart( PGM_BASE*, int, KIWAY* ) override { return true; }
    wxWindow* CreateKiWindow( wxWindow*, int, KIWAY*, int ) override { return nullptr; }
    void* IfaceOrAddress( int ) override { return nullptr; }
};
} // namespace

KIFACE_BASE& Kiface()
{
    static LIBKICAD_STUB_KIFACE instance;
    return instance;
}
