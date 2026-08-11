import Cocoa

/// Shared body for the currently-empty sub-entry placeholder view controllers (GeometryViewController,
/// SimulationResultsViewController, FieldViewerViewController) -- a centered, muted label naming the
/// section, matching DocumentWindowController's "No Simulation Selected" empty-state look.
enum SubEntryPlaceholder {
    static func makeView(title: String) -> NSView {
        let container = NSView()

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }
}
