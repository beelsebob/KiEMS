import Cocoa

/// Content for a simulation's "Simulation Results" sub-entry, selected via
/// SimulationListViewController's outline view. Empty for now -- will eventually show S-parameters
/// and other post-processed results once running a simulation is supported.
final class SimulationResultsViewController: NSViewController {
    override func loadView() {
        view = SubEntryPlaceholder.makeView(title: "Simulation Results")
    }
}
