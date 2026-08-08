#include "libkicad.hpp"

#include <memory>

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

namespace
{
// PGM_BASE has exactly one pure-virtual method; a minimal, non-mock, real subclass covers it.
class MINIMAL_PGM : public PGM_BASE
{
public:
    void MacOpenFile( const wxString& ) override {}
};

bool ensureWxInitialized()
{
    static bool initialized = false;

    if( initialized )
        return true;

    wxApp::SetInstance( new wxAppConsole() );
    int argc = 0;

    if( !wxInitialize( argc, static_cast<char**>( nullptr ) ) )
        return false;

    SetPgm( new MINIMAL_PGM() );
    initialized = true;
    return true;
}
} // namespace

LibKicadPadQueryResult LibKicadCountPads( const std::string& projectPath, const std::string& boardPath )
{
    LibKicadPadQueryResult result;

    if( !ensureWxInitialized() )
    {
        result.errorMessage = "wxInitialize failed";
        return result;
    }

    SETTINGS_MANAGER settingsManager;
    wxString wxProjectPath = wxString::FromUTF8( projectPath );

    if( !settingsManager.LoadProject( wxProjectPath ) )
    {
        result.errorMessage = "LoadProject failed";
        return result;
    }

    PROJECT* project = settingsManager.GetProject( wxProjectPath );

    if( !project )
    {
        result.errorMessage = "GetProject returned null";
        return result;
    }

    // Bypass PCB_IO_MGR's format registry (which unconditionally links in every foreign-format
    // importer, per pcbnew/pcb_io/pcb_io_mgr.cpp's static REGISTER_PLUGIN globals) and go
    // straight to the one real KiCad-format plugin we need. This is still the exact same
    // LoadBoard() implementation PCB_IO_MGR would have dispatched to for KICAD_SEXP.
    PCB_IO_KICAD_SEXPR plugin;
    wxString wxBoardPath = wxString::FromUTF8( boardPath );
    std::unique_ptr<BOARD> board( plugin.LoadBoard( wxBoardPath, nullptr, nullptr, project ) );

    if( !board )
    {
        result.errorMessage = "LoadBoard failed";
        return result;
    }

    result.footprintCount = static_cast<int>( board->Footprints().size() );
    result.trackCount = static_cast<int>( board->Tracks().size() );
    result.zoneCount = static_cast<int>( board->Zones().size() );

    auto context = std::make_shared<HEADLESS_PCB_CONTEXT>( std::move( board ), project, nullptr );

    if( !context->GetBoard() )
    {
        result.errorMessage = "HEADLESS_PCB_CONTEXT has no board";
        return result;
    }

    API_HANDLER_PCB handler( context, nullptr );

    // Drive the query purely via protobuf -- exactly what the real API server does with a
    // message that arrived over the wire.
    kiapi::common::commands::GetItems getItems;
    getItems.mutable_header()->mutable_document()->set_type( kiapi::common::types::DocumentType::DOCTYPE_PCB );
    getItems.mutable_header()->mutable_document()->set_board_filename( wxFileName( wxBoardPath ).GetFullName().ToStdString() );
    getItems.add_types( kiapi::common::types::KOT_PCB_PAD );

    kiapi::common::ApiRequest request;
    request.mutable_header()->set_client_name( "libkicad-smoketest" );

    if( !request.mutable_message()->PackFrom( getItems ) )
    {
        result.errorMessage = "Failed to pack GetItems into request";
        return result;
    }

    API_RESULT apiResult = handler.Handle( request );

    if( !apiResult.has_value() )
    {
        result.errorMessage = "Handle() failed: status=" + std::to_string( apiResult.error().status() )
                               + " message=" + apiResult.error().error_message();
        return result;
    }

    kiapi::common::commands::GetItemsResponse itemsResponse;

    if( !apiResult.value().message().UnpackTo( &itemsResponse ) )
    {
        result.errorMessage = "Failed to unpack GetItemsResponse";
        return result;
    }

    result.padCount = itemsResponse.items_size();
    result.success = true;
    return result;
}
