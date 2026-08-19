import Cocoa

/// Content for a simulation's "Geometry" sub-entry, selected via SimulationListViewController's
/// outline view. Runs the shared per-simulation pipeline (Document.pipeline(forSimulationNamed:),
/// EMSSimulationPipelineBridge) up through its Geometry stage in the background the first time a
/// given simulation's Geometry entry is shown, then renders the result with GeometryView. The
/// pipeline itself caches the built geometry (shared with SimulationResultsViewController, so a
/// later Results run doesn't re-slice/re-grid); this view controller only tracks its own in-flight/
/// error state, since "is the geometry step running" and "did it just fail" aren't things the shared
/// pipeline remembers on its own.
final class GeometryViewController: NSViewController {
    private weak var document: Document?

    private let geometryView = GeometryView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let timeEstimateLabel = NSTextField(labelWithString: "")
    private let showGridCheckbox = NSButton(checkboxWithTitle: "Show Grid", target: nil, action: nil)

    private var errors: [Int: String] = [:]
    private var runningIndices: Set<Int> = []
    // A separate in-flight set from runningIndices -- see runGridOnlyStep()'s own doc comment for
    // why toggling the overlay on for a simulation whose geometry is already showing must never hide
    // that already-good view behind the "Processing…" status label the way runningIndices does.
    private var gridOnlyRunningIndices: Set<Int> = []
    // Per-simulation "Show Grid" checkbox state -- keyed by index (not a single shared Bool) so
    // switching between simulations remembers each one's own choice, matching errors/runningIndices'
    // own per-index convention. Absent (not false) until the user actually checks it once.
    private var gridOverlayEnabled: [Int: Bool] = [:]
    // Latest known geometry-phase progress fraction (0...1) per simulation, from this VC's own
    // in-flight ensureStage: call -- kept so refreshDisplay() (called on re-selection, not just from
    // the live progress callback) can restore the progress bar to where it actually is.
    private var progressFraction: [Int: Double] = [:]
    // When runStep()'s own in-flight run for a simulation started -- the basis for the elapsed-time/
    // fraction extrapolation behind timeEstimateLabel's own text (see progressReceived()). Not
    // touched by runGridOnlyStep(): that path never shows the progress bar/time estimate at all (see
    // runGridOnlyStep()'s own doc comment), so there's nothing for it to extrapolate for.
    private var runStartTime: [Int: Date] = [:]
    // Latest known time-remaining text per simulation, mirroring progressFraction's own "so
    // refreshDisplay() can restore state on re-selection" role.
    private var timeEstimateText: [Int: String] = [:]
    private var currentIndex: Int?

    /// Fired whenever a given simulation's geometry step starts/finishes running, so
    /// DocumentWindowController can relay it to SimulationListViewController's spinner.
    var onRunStateChanged: ((Int, Bool) -> Void)?

    /// Fired once runStep()'s (not the quiet runGridOnlyStep()'s) in-flight run finishes for a given
    /// simulation, with whether it succeeded -- so DocumentWindowController can set the "Geometry"
    /// row's status icon (green/yellow) once its busy spinner clears. Deliberately not fired from
    /// gridOnlyStepFinished(): a failed grid-overlay-only fetch doesn't invalidate the already-good
    /// geometry that's still showing (see runGridOnlyStep()'s own doc comment), so it shouldn't flip
    /// the row to an error state either.
    var onRunFinished: ((Int, Bool) -> Void)?

    /// Fired with every EMSPipelineProgress this VC's own in-flight ensureStage: call reports, so
    /// DocumentWindowController can relay it to SimulationListViewController's circular progress
    /// indicator for the "Geometry" row. Always phase == .geometry here -- this VC only ever
    /// requests .geometry/.grid, never .results, so a .simulation-phase report can never happen from
    /// a run *this* VC triggered (though the Geometry row still needs updating from a
    /// SimulationResultsViewController-triggered run -- see that VC's own onProgressChanged).
    var onProgressChanged: ((Int, EMSPipelineProgress) -> Void)?

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
        // See SimulationResultsViewController's identical statusLabel setup for why this is needed --
        // without it, this multi-line label's intrinsic width can come back unwrapped-and-huge,
        // which an Auto-Layout-sized window then grows to accommodate.
        statusLabel.preferredMaxLayoutWidth = 400
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressBar)

        timeEstimateLabel.font = .systemFont(ofSize: 11)
        timeEstimateLabel.textColor = .tertiaryLabelColor
        timeEstimateLabel.alignment = .center
        timeEstimateLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(timeEstimateLabel)

        showGridCheckbox.target = self
        showGridCheckbox.action = #selector(toggleGridOverlay(_:))
        // Dark-appropriate control tint -- this whole view is a fixed dark canvas (see GeometryView's
        // own backgroundColor doc comment) regardless of the app's light/dark appearance, so an
        // adaptive-appearance checkbox needs pinning the same way GeometryView's legend text does.
        showGridCheckbox.appearance = NSAppearance(named: .darkAqua)
        showGridCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(showGridCheckbox)

        // Vertically centers the *whole* statusLabel...timeEstimateLabel block (not just statusLabel
        // itself) in the container -- an invisible NSLayoutGuide spanning the block, rather than
        // hardcoding a compensating offset for the progress bar/label's own height, so this stays
        // correct if that content ever changes again. Without it, centering statusLabel alone (as
        // when it was the only content here) leaves the extra rows below it pushing the whole block's
        // visual center below the container's true center.
        let contentGuide = NSLayoutGuide()
        container.addLayoutGuide(contentGuide)

        NSLayoutConstraint.activate([
            geometryView.topAnchor.constraint(equalTo: container.topAnchor),
            geometryView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            geometryView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            geometryView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentGuide.topAnchor.constraint(equalTo: statusLabel.topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: timeEstimateLabel.bottomAnchor),
            contentGuide.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            progressBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 240),

            timeEstimateLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            timeEstimateLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            showGridCheckbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            showGridCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])

        view = container
    }

    /// Called by DocumentWindowController whenever the user selects a simulation's "Geometry"
    /// sub-entry (including re-selecting one already showing). Shows a cached result or error
    /// immediately if there is one; otherwise kicks off the geometry step in the background.
    func showGeometry(forSimulationIndex index: Int) {
        currentIndex = index
        refreshDisplay()

        guard let document, index < document.config.simulations.count else { return }
        let name = document.config.simulations[index].name
        let pipeline = document.pipeline(forSimulationNamed: name)
        // If this simulation's own "Show Grid" checkbox is already on (from a previous visit, or
        // because a Results run already computed it -- see EMSSimulationPipelineBridge.h's own doc
        // comment on stage sharing), go straight for .grid: ensureStage: computes .geometry as an
        // unavoidable step on the way there anyway, so there's no separate "geometry first, grid
        // later" request needed here even on a simulation never visited before.
        let targetStage: EMSPipelineStage = (gridOverlayEnabled[index] ?? false) ? .grid : .geometry
        guard !pipeline.hasStage(targetStage), errors[index] == nil, !runningIndices.contains(index) else { return }
        runStep(forSimulationIndex: index, simulationName: name, pipeline: pipeline, stage: targetStage)
    }

    /// Called by DocumentWindowController whenever something that would change this simulation's
    /// built geometry changes -- a hull-padding/via/ground-net edit (SimulationPropertiesViewController.
    /// onGeometryParametersChanged) or its involved-nets membership/impedance/plane/width
    /// (SourceListViewController.onInvolvedNetsChanged) -- so a stale cached result (or error) from
    /// before the edit doesn't keep being shown. Deliberately doesn't re-run immediately, even if
    /// this simulation's Geometry entry is the one currently showing: just invalidates the shared
    /// pipeline's cache from the Geometry stage onward (which also drops any cached Results, since
    /// those were built from the now-stale geometry) and clears this VC's own error, so the next
    /// explicit Geometry selection (showGeometry) is what triggers the real re-run.
    func invalidateCache(forSimulationIndex index: Int) {
        errors[index] = nil
        guard let document, index < document.config.simulations.count else { return }
        document.pipeline(forSimulationNamed: document.config.simulations[index].name)
            .invalidate(from: .geometry)
    }

    /// Toggled from the "Show Grid" checkbox -- see showGridCheckbox's own doc comment for why this
    /// is per-simulation state, not a single shared flag.
    @objc private func toggleGridOverlay(_ sender: NSButton) {
        guard let currentIndex else { return }
        let enabled = sender.state == .on
        gridOverlayEnabled[currentIndex] = enabled
        refreshDisplay()
        guard enabled, let document, currentIndex < document.config.simulations.count else { return }
        let name = document.config.simulations[currentIndex].name
        let pipeline = document.pipeline(forSimulationNamed: name)
        // Every other case (still loading, in error, or this simulation not visited yet at all) is
        // already covered by showGeometry()'s own targetStage logic picking .grid the next time this
        // simulation is (re-)selected -- a separate fetch is only needed here for the one case that
        // logic can't reach: geometry is already showing right now, so nothing will re-select it.
        guard pipeline.hasStage(.geometry), !pipeline.hasStage(.grid), errors[currentIndex] == nil,
              !gridOnlyRunningIndices.contains(currentIndex) else { return }
        runGridOnlyStep(forSimulationIndex: currentIndex, simulationName: name, pipeline: pipeline)
    }

    private func refreshDisplay() {
        guard let currentIndex, let document, currentIndex < document.config.simulations.count else {
            showGridCheckbox.isHidden = true
            return
        }
        let name = document.config.simulations[currentIndex].name
        let pipeline = document.pipeline(forSimulationNamed: name)
        let wantsGrid = gridOverlayEnabled[currentIndex] ?? false
        showGridCheckbox.state = wantsGrid ? .on : .off

        if let preview = pipeline.geometryPreview() {
            geometryView.preview = preview
            geometryView.showGrid = wantsGrid
            geometryView.isHidden = false
            statusLabel.isHidden = true
            progressBar.isHidden = true
            timeEstimateLabel.isHidden = true
            showGridCheckbox.isHidden = false
        } else if let error = errors[currentIndex] {
            geometryView.isHidden = true
            statusLabel.stringValue = error
            statusLabel.isHidden = false
            progressBar.isHidden = true
            timeEstimateLabel.isHidden = true
            showGridCheckbox.isHidden = true
        } else if runningIndices.contains(currentIndex) {
            geometryView.isHidden = true
            statusLabel.stringValue = wantsGrid ? "Processing Geometry and Grid…" : "Processing Geometry…"
            statusLabel.isHidden = false
            progressBar.doubleValue = progressFraction[currentIndex] ?? 0
            progressBar.isHidden = false
            timeEstimateLabel.stringValue = timeEstimateText[currentIndex]
                ?? TimeRemainingFormatter.string(secondsRemaining: nil)
            timeEstimateLabel.isHidden = false
            showGridCheckbox.isHidden = true
        } else {
            geometryView.isHidden = true
            statusLabel.isHidden = true
            progressBar.isHidden = true
            timeEstimateLabel.isHidden = true
            showGridCheckbox.isHidden = true
        }
    }

    private func runStep(forSimulationIndex index: Int, simulationName: String,
                          pipeline: EMSSimulationPipelineBridge, stage: EMSPipelineStage) {
        guard let document else { return }
        let config = document.config
        // Always a private scratch directory, migrated into the real package only at save time --
        // see pipelineDirectory's doc comment for why it's never the real package directly. Doesn't
        // require saving first either way.
        let packageDir = document.pipelineDirectory.path
        let kicadCliPath = AppPaths.resolveKicadCli()
        let helperPath = AppPaths.kicadQueryHelperPath

        runningIndices.insert(index)
        runStartTime[index] = Date()
        onRunStateChanged?(index, true)
        refreshDisplay()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try pipeline.ensureStage(stage, config: config, packageDir: packageDir,
                                          kicadCliPath: kicadCliPath, kicadQueryHelperPath: helperPath,
                                          progress: { progress in
                                              DispatchQueue.main.async {
                                                  self?.progressReceived(progress, forSimulationIndex: index)
                                              }
                                          })
                DispatchQueue.main.async {
                    self?.stepFinished(forSimulationIndex: index, error: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.stepFinished(forSimulationIndex: index, error: error)
                }
            }
        }
    }

    /// Common handler for every EMSPipelineProgress report from either runStep()'s or
    /// runGridOnlyStep()'s own in-flight ensureStage: call -- relayed outward via onProgressChanged
    /// (for the source-list row) and, if this is the currently-shown simulation, applied to this
    /// VC's own progress bar/time estimate too.
    private func progressReceived(_ progress: EMSPipelineProgress, forSimulationIndex index: Int) {
        progressFraction[index] = progress.fraction
        onProgressChanged?(index, progress)
        print("[\(simulationName(forIndex: index))] Geometry: \(Int((progress.fraction * 100).rounded()))%")
        // Simple linear extrapolation from elapsed time and how far through this run we are --
        // runGridOnlyStep() never sets runStartTime, so this stays nil (-> "Calculating…") for that
        // path, which is fine since its progress never reaches this VC's own progress bar anyway.
        let secondsRemaining: Double?
        if let start = runStartTime[index], progress.fraction > 0 {
            let elapsed = Date().timeIntervalSince(start)
            secondsRemaining = max(0, elapsed / progress.fraction - elapsed)
        } else {
            secondsRemaining = nil
        }
        let estimateText = TimeRemainingFormatter.string(secondsRemaining: secondsRemaining)
        timeEstimateText[index] = estimateText
        if currentIndex == index, runningIndices.contains(index) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                progressBar.animator().doubleValue = progress.fraction
            }
            timeEstimateLabel.stringValue = estimateText
        }
    }

    private func simulationName(forIndex index: Int) -> String {
        guard let document, index < document.config.simulations.count else { return "simulation \(index)" }
        return document.config.simulations[index].name
    }

    private func stepFinished(forSimulationIndex index: Int, error: Error?) {
        runningIndices.remove(index)
        progressFraction[index] = nil
        runStartTime[index] = nil
        timeEstimateText[index] = nil
        // Immediate, not animated -- the bar's about to be hidden by refreshDisplay() below anyway,
        // but resetting it here (rather than leaving it sitting at its last live value) means the
        // *next* run for this same simulation starts from a true 0, not an animated slide down from
        // wherever this one left off.
        progressBar.doubleValue = 0
        onRunStateChanged?(index, false)
        onRunFinished?(index, error == nil)
        if let error {
            errors[index] = error.localizedDescription
        } else {
            document?.updateChangeCount(.changeDone)
        }
        refreshDisplay()
    }

    /// A quiet, non-blocking follow-up fetch for when "Show Grid" gets checked *after* this
    /// simulation's geometry is already showing -- unlike runStep(...)/stepFinished(...), this never
    /// touches runningIndices/onRunStateChanged or hides the already-good geometryView behind the
    /// "Processing…" status label; refreshDisplay() just picks up the richer (grid-line-including)
    /// preview once ensureStage:.grid lands.
    private func runGridOnlyStep(forSimulationIndex index: Int, simulationName: String,
                                  pipeline: EMSSimulationPipelineBridge) {
        guard let document else { return }
        let config = document.config
        let packageDir = document.pipelineDirectory.path
        let kicadCliPath = AppPaths.resolveKicadCli()
        let helperPath = AppPaths.kicadQueryHelperPath

        gridOnlyRunningIndices.insert(index)
        // Only the *row* spinner, not this VC's own runningIndices/refreshDisplay() -- see this
        // method's own doc comment for why the main content view must stay untouched here.
        onRunStateChanged?(index, true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try pipeline.ensureStage(.grid, config: config, packageDir: packageDir,
                                          kicadCliPath: kicadCliPath, kicadQueryHelperPath: helperPath,
                                          progress: { progress in
                                              DispatchQueue.main.async {
                                                  self?.progressReceived(progress, forSimulationIndex: index)
                                              }
                                          })
                DispatchQueue.main.async {
                    self?.gridOnlyStepFinished(forSimulationIndex: index, error: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.gridOnlyStepFinished(forSimulationIndex: index, error: error)
                }
            }
        }
    }

    private func gridOnlyStepFinished(forSimulationIndex index: Int, error: Error?) {
        gridOnlyRunningIndices.remove(index)
        progressFraction[index] = nil
        onRunStateChanged?(index, false)
        if error != nil {
            // The already-shown geometry stays valid and visible; only the overlay itself failed --
            // uncheck it rather than hiding good geometry behind an error the user didn't cause by
            // editing anything themselves, and there's no persistent secondary-error UI surface in
            // this view to show it in without disrupting the main display.
            gridOverlayEnabled[index] = false
        } else {
            document?.updateChangeCount(.changeDone)
        }
        refreshDisplay()
    }
}
