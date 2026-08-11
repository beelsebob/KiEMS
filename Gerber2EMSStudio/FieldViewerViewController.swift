import Cocoa

/// Content for a simulation's "Field Viewer" sub-entry, selected via SimulationListViewController's
/// outline view. Empty for now -- will eventually visualize FDTD field data for the simulation.
final class FieldViewerViewController: NSViewController {
    override func loadView() {
        view = SubEntryPlaceholder.makeView(title: "Field Viewer")
    }
}
