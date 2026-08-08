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

// This entire file is glue code defining real KiCad class members (base-class initializers,
// wx/std types in signatures, ...), so there's no clean boundary between "our code" and "KiCad's
// headers" to scope diagnostics around -- silence KiCad/wx's own warnings for the whole file
// rather than "our" code, which is these stub bodies, all directly built from their declarations.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"

#include <board_loader.h>
#include <pcb_edit_frame.h>
#include <netlist_reader/board_netlist_updater.h>
#include <netlist_reader/pcb_netlist_utils.h>
#include <tools/pcb_selection_tool.h>
#include <project_pcb.h>
#include <3d_cache/3d_cache.h>
#include <3d_viewer/eda_3d_viewer_frame.h>
#include <3d_viewer/eda_3d_viewer_settings.h>
#include <navlib/nl_pcbnew_plugin.h>
#include <navlib/nl_pcbnew_plugin_impl.h>
#include <3d_navlib/nl_3d_viewer_plugin.h>
#include <3d_canvas/board_adapter.h>
#include <3d_rendering/track_ball.h>
#include <pcb_io/odbpp/pcb_io_odbpp.h>
#include <pcb_io/ipc2581/pcb_io_ipc2581.h>
#include <zone_filler.h>
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
// The destructor (declared before Init() in the class body, non-inline) is PCB_SELECTION_TOOL's
// real key function -- its typeinfo is a plain data symbol that dyld binds eagerly at load time
// (unlike the lazily-resolved function pointers -Wl,-undefined,dynamic_lookup covers elsewhere in
// this file), so it has to actually resolve, even though nothing here ever touches it at runtime.
// Its m_priv member is a pimpl (std::unique_ptr<PRIV>) whose real definition lives only in
// pcb_selection_tool.cpp, which we don't build, so the implicit member cleanup in our destructor
// needs *some* complete PRIV type to call delete on. We never actually construct a
// PCB_SELECTION_TOOL (only its typeinfo is referenced, for dynamic_cast/typeid checks in code we
// never execute), so m_priv is always null here regardless of layout -- an empty stand-in type is
// safe precisely because "delete"-ing a null pointer never touches it.
class PCB_SELECTION_TOOL::PRIV
{
};

PCB_SELECTION_TOOL::~PCB_SELECTION_TOOL()
{
}

bool PCB_SELECTION_TOOL::Init()
{
    return false;
}

// Defining the destructor as the key function means PCB_SELECTION_TOOL's vtable is emitted here
// too, and unlike lazily-bound function calls, a vtable is data that dyld resolves eagerly at
// load -- every non-pure virtual override needs a real symbol, not just Init()/GetSelection().
void PCB_SELECTION_TOOL::Reset( TOOL_BASE::RESET_REASON )
{
}

void PCB_SELECTION_TOOL::setTransitions()
{
}

void PCB_SELECTION_TOOL::EnterGroup()
{
}

void PCB_SELECTION_TOOL::ExitGroup( bool )
{
}

bool PCB_SELECTION_TOOL::ctrlClickHighlights()
{
    return false;
}

void PCB_SELECTION_TOOL::select( EDA_ITEM* )
{
}

void PCB_SELECTION_TOOL::unselect( EDA_ITEM* )
{
}

void PCB_SELECTION_TOOL::highlight( EDA_ITEM*, int, SELECTION* )
{
}

void PCB_SELECTION_TOOL::unhighlight( EDA_ITEM*, int, SELECTION* )
{
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

// -- 3d_viewer / navlib ---------------------------------------------------------------------------
// Note: pcb_base_frame.cpp.o and footprint_library_adapter.cpp.o (real KiCad code, defining
// PCB_BASE_FRAME::SetDisplayOptions/GetPcbNewSettings and FOOTPRINT_LIBRARY_ADAPTER) end up in the
// link regardless of anything here -- something else in pcbcommon.a needs them -- so we don't stub
// those ourselves (that would just be a duplicate-symbol clash). -Wl,-undefined,dynamic_lookup on
// the smoketest target covers plain function calls those pull in that we never reach at runtime
// (e.g. PCB_IO_MGR's foreign-format importers), but it does NOT cover typeinfo/vtable data symbols
// -- those get bound eagerly at process load regardless of whether the code behind them ever runs,
// so PCB_BASE_FRAME::Get3DViewerFrame()'s dynamic_cast<EDA_3D_VIEWER_FRAME*> forces us to actually
// define that class's vtable (and everything reachable from defining it) below, the same way
// PCB_SELECTION_TOOL's did above.
BOARD_ADAPTER::BOARD_ADAPTER()
{
}

BOARD_ADAPTER::~BOARD_ADAPTER()
{
}

TRACK_BALL::TRACK_BALL( float aInitialDistance ) : CAMERA( aInitialDistance )
{
}

// TRACK_BALL's destructor is inline, so its key function is Drag() (the first out-of-line
// virtual) -- same vtable-is-data-and-needs-every-slot story as PCB_SELECTION_TOOL above.
void TRACK_BALL::Drag( const wxPoint& )
{
}

void TRACK_BALL::Pan( const wxPoint& )
{
}

void TRACK_BALL::Pan( const SFVEC3F& )
{
}

void TRACK_BALL::Pan_T1( const SFVEC3F& )
{
}

void TRACK_BALL::Reset_T1()
{
}

void TRACK_BALL::SetT0_and_T1_current_T()
{
}

void TRACK_BALL::Interpolate( float )
{
}

// Minimal (empty) event table: DECLARE_EVENT_TABLE() in the header requires GetEventTable()/
// GetEventHashTable() to be defined somewhere, and the real eda_3d_viewer_frame.cpp (which we
// don't build) supplies them via BEGIN_EVENT_TABLE/END_EVENT_TABLE. An empty table is a real,
// legitimate definition, not a stand-in -- it just binds no extra handlers.
BEGIN_EVENT_TABLE( EDA_3D_VIEWER_FRAME, KIWAY_PLAYER )
END_EVENT_TABLE()

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

void EDA_3D_VIEWER_FRAME::LoadSettings( APP_SETTINGS_BASE* )
{
}

void EDA_3D_VIEWER_FRAME::SaveSettings( APP_SETTINGS_BASE* )
{
}

void EDA_3D_VIEWER_FRAME::doReCreateMenuBar()
{
}

void EDA_3D_VIEWER_FRAME::setupUIConditions()
{
}

void EDA_3D_VIEWER_FRAME::handleIconizeEvent( wxIconizeEvent& )
{
}

void EDA_3D_VIEWER_FRAME::ShowChangedLanguage()
{
}

void EDA_3D_VIEWER_FRAME::CommonSettingsChanged( int )
{
}

bool EDA_3D_VIEWER_FRAME::TryBefore( wxEvent& )
{
    return false;
}

APP_SETTINGS_BASE* EDA_3D_VIEWER_FRAME::config() const
{
    return nullptr;
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

NL_PCBNEW_PLUGIN::~NL_PCBNEW_PLUGIN()
{
}

void NL_PCBNEW_PLUGIN::SetFocus( bool )
{
}

// -- pcb_io/odbpp, pcb_io/ipc2581 -----------------------------------------------------------------
// Unlike the other 13 foreign-format importers PCB_IO_MGR's static registry references (whose
// constructors are out-of-line, so `new PCB_IO_X()` inside the registry's lambda is just a lazy
// function call that -Wl,-undefined,dynamic_lookup can defer), these two have inline constructors
// -- the lambda inlines them directly, embedding a compile-time reference to the vtable itself,
// which needs eager resolution just like the typeinfo/vtable cases above.
PCB_IO_ODBPP::~PCB_IO_ODBPP()
{
}

std::vector<FOOTPRINT*> PCB_IO_ODBPP::GetImportedCachedLibraryFootprints()
{
    notImplemented( "PCB_IO_ODBPP::GetImportedCachedLibraryFootprints" );
}

void PCB_IO_ODBPP::SaveBoard( const wxString&, BOARD*, const std::map<std::string, UTF8>* )
{
    notImplemented( "PCB_IO_ODBPP::SaveBoard" );
}

PCB_IO_IPC2581::~PCB_IO_IPC2581()
{
}

std::vector<FOOTPRINT*> PCB_IO_IPC2581::GetImportedCachedLibraryFootprints()
{
    notImplemented( "PCB_IO_IPC2581::GetImportedCachedLibraryFootprints" );
}

void PCB_IO_IPC2581::SaveBoard( const wxString&, BOARD*, const std::map<std::string, UTF8>* )
{
    notImplemented( "PCB_IO_IPC2581::SaveBoard" );
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

#pragma clang diagnostic pop
