import Cocoa

/// Content for a simulation's "Geometry" sub-entry, selected via SimulationListViewController's
/// outline view. Runs the real geometry-building pipeline step (GeometryPreviewBridge, which mirrors
/// `geber2ems -g`) in the background the first time a given simulation's Geometry entry is shown,
/// then renders the result with GeometryView. Results (and errors) are cached per simulation index,
/// so re-selecting an already-built simulation's Geometry entry doesn't re-run the pipeline.
final class GeometryViewController: NSViewController {
    private weak var document: Document?

    private let geometryView = GeometryView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var previews: [Int: EMSGeometryPreview] = [:]
    private var errors: [Int: String] = [:]
    private var runningIndices: Set<Int> = []
    private var currentIndex: Int?

    /// Fired whenever a given simulation's geometry step starts/finishes running, so
    /// DocumentWindowController can relay it to SimulationListViewController's spinner.
    var onRunStateChanged: ((Int, Bool) -> Void)?

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        geometryView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(geometryView)

        statusLabel.font = .systemFont(ofSize: 20, weight: .medium) // Matches SubEntryPlaceholder's notice text.
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            geometryView.topAnchor.constraint(equalTo: container.topAnchor),
            geometryView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            geometryView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            geometryView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])

        view = container
    }

    /// Called by DocumentWindowController whenever the user selects a simulation's "Geometry"
    /// sub-entry (including re-selecting one already showing). Shows a cached result or error
    /// immediately if there is one; otherwise kicks off the geometry step in the background.
    func showGeometry(forSimulationIndex index: Int) {
        currentIndex = index
        refreshDisplay()

        guard previews[index] == nil, errors[index] == nil, !runningIndices.contains(index) else { return }
        runGeometryStep(forSimulationIndex: index)
    }

    /// Called by DocumentWindowController whenever something that would change this simulation's
    /// built geometry changes -- a hull-padding/via/ground-net edit (SimulationPropertiesViewController.
    /// onGeometryParametersChanged) or its involved-nets membership/impedance/plane/width
    /// (SourceListViewController.onInvolvedNetsChanged) -- so a stale cached result (or error) from
    /// before the edit doesn't keep being shown. Deliberately doesn't re-run immediately, even if
    /// this simulation's Geometry entry is the one currently showing: just clears the cache, so the
    /// next explicit Geometry selection (showGeometry) is what triggers the real re-run.
    func invalidateCache(forSimulationIndex index: Int) {
        previews[index] = nil
        errors[index] = nil
    }

    private func refreshDisplay() {
        guard let currentIndex else { return }
        if let preview = previews[currentIndex] {
            geometryView.preview = preview
            geometryView.isHidden = false
            statusLabel.isHidden = true
        } else if let error = errors[currentIndex] {
            geometryView.isHidden = true
            statusLabel.stringValue = error
            statusLabel.isHidden = false
        } else if runningIndices.contains(currentIndex) {
            geometryView.isHidden = true
            statusLabel.stringValue = "Processing Geometry…"
            statusLabel.isHidden = false
        } else {
            geometryView.isHidden = true
            statusLabel.isHidden = true
        }
    }

    private func runGeometryStep(forSimulationIndex index: Int) {
        guard let document, index < document.config.simulations.count else { return }

        let simulationName = document.config.simulations[index].name
        let config = document.config
        // Always a private scratch directory, migrated into the real package only at save time --
        // see pipelineDirectory's doc comment for why it's never the real package directly. Doesn't
        // require saving first either way.
        let packageDir = document.pipelineDirectory.path
        let kicadCliPath = AppPaths.resolveKicadCli()
        let helperPath = AppPaths.kicadQueryHelperPath
        let workerPath = AppPaths.fdtdWorkerPath

        runningIndices.insert(index)
        onRunStateChanged?(index, true)
        refreshDisplay()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let preview = try EMSGeometryStepBridge.runGeometryStep(
                    forSimulationNamed: simulationName, config: config, packageDir: packageDir,
                    kicadCliPath: kicadCliPath, kicadQueryHelperPath: helperPath, fdtdWorkerPath: workerPath)
                DispatchQueue.main.async {
                    self?.geometryStepFinished(forSimulationIndex: index, preview: preview, error: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.geometryStepFinished(forSimulationIndex: index, preview: nil, error: error)
                }
            }
        }
    }

    private func geometryStepFinished(forSimulationIndex index: Int, preview: EMSGeometryPreview?, error: Error?) {
        runningIndices.remove(index)
        onRunStateChanged?(index, false)
        if let preview {
            previews[index] = preview
            document?.updateChangeCount(.changeDone)
        } else {
            errors[index] = error?.localizedDescription ?? "Geometry step failed."
        }
        refreshDisplay()
    }
}
