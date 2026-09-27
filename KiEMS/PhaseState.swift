import Foundation

/// The status of one simulation's one pipeline phase (JobKind: Geometry, Simulation, or Field
/// Viewer), as tracked centrally by SimulationListViewController's own phaseStates store. This is
/// the single vocabulary every sidebar row indicator (and any other progress UI) should read --
/// previously each of the 3 rows derived its own status independently from whichever view
/// controller happened to relay it, which let a phase-agnostic signal (e.g. FieldViewerViewController
/// watching its own geometry/simulation prerequisites) leak into the wrong row's indicator. Routing
/// every update explicitly by JobKind (see DocumentWindowController's wiring) is what keeps that
/// from happening again.
enum PhaseState: Equatable {
    /// Never computed, or invalidated by a config edit since it last ran -- matches
    /// EMSSimulationPipelineBridge's own stage-cache-miss/invalidateFromStage: semantics. Also the
    /// default for a phase with no stored entry at all (a simulation that's never been touched).
    case invalid
    /// Actively running (or queued behind another simulation's own in-flight job -- JobScheduler
    /// runs one job at a time, app-wide), `fraction` 0...1 within this phase. `fraction` is 0 the
    /// moment a phase is known to have started but hasn't reported real progress yet.
    case inProgress(fraction: Double)
    case succeeded
    case failed
}
