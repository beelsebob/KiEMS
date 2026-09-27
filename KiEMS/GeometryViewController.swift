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
    private let progressStatus = ProgressStatusView()
    private let showGridCheckbox = NSButton(checkboxWithTitle: "Show Grid", target: nil, action: nil)

    private var errors: [Int: String] = [:]
    // Mirrors JobScheduler's own status for this simulation's .geometryGeneration job -- see
    // syncFromScheduler(). Not the source of truth (JobScheduler.jobs is), just this VC's own cached
    // view of it for refreshDisplay() to read synchronously.
    private var runningIndices: Set<Int> = []
    // Per-simulation "Show Grid" checkbox state -- keyed by index (not a single shared Bool) so
    // switching between simulations remembers each one's own choice, matching errors/runningIndices'
    // own per-index convention. Absent (not false) until the user actually checks it once.
    private var gridOverlayEnabled: [Int: Bool] = [:]
    // Latest known geometry-phase progress fraction (0...1) per simulation, from JobScheduler's own
    // job.progress -- kept so refreshDisplay() (called on re-selection, not just from
    // syncFromScheduler()) can restore the progress bar to where it actually is.
    private var progressFraction: [Int: Double] = [:]
    // When this simulation's own job was first observed running -- the basis for the elapsed-time/
    // fraction extrapolation behind progressStatus's own time-estimate label (see progressReceived()).
    private var runStartTime: [Int: Date] = [:]
    // Latest known time-remaining text per simulation, mirroring progressFraction's own "so
    // refreshDisplay() can restore state on re-selection" role.
    private var timeEstimateText: [Int: String] = [:]
    private var currentIndex: Int?
    private var layerCatalogs: [Int: EMSGeometryPreview] = [:]
    private var layerLoaders: [Int: BoardLayerGeometryLoader] = [:]
    private var loadingLayerCatalogs: Set<Int> = []
    private var mergedDetailedPreview: Set<Int> = []

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

    /// Fired when a simulation's geometry job was cancelled (via the Jobs window), as opposed to
    /// finishing with a real error -- see JobScheduler's own doc comment on why that's a distinct
    /// outcome from onRunFinished(_:false): the user asked for this, so there's nothing to show as
    /// an error, just nothing yet. DocumentWindowController wires this to
    /// SimulationListViewController.setInvalid(forSimulationIndex:kind: .geometryGeneration).
    var onRunCancelled: ((Int) -> Void)?

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
        JobScheduler.shared.addChangeObserver { [weak self] in self?.syncFromScheduler() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        geometryView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(geometryView)

        progressStatus.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressStatus)

        showGridCheckbox.target = self
        showGridCheckbox.action = #selector(toggleGridOverlay(_:))
        // Dark-appropriate control tint -- this whole view is a fixed dark canvas (see GeometryView's
        // own backgroundColor doc comment) regardless of the app's light/dark appearance, so an
        // adaptive-appearance checkbox needs pinning the same way GeometryView's legend text does.
        showGridCheckbox.appearance = NSAppearance(named: .darkAqua)
        showGridCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(showGridCheckbox)

        NSLayoutConstraint.activate([
            geometryView.topAnchor.constraint(equalTo: container.topAnchor),
            geometryView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            geometryView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            geometryView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            progressStatus.topAnchor.constraint(equalTo: container.topAnchor),
            progressStatus.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressStatus.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressStatus.bottomAnchor.constraint(equalTo: container.bottomAnchor),

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
        loadLayerCatalogIfNeeded(forSimulationIndex: index)
        refreshDisplay()

        guard let document, index < document.config.simulations.count else { return }
        let name = document.config.simulations[index].name
        let pipeline = document.pipeline(forSimulationNamed: name)
        // .geometryGeneration's own job always computes grid lines too, not just the sliced board
        // (see JobKind's own doc comment) -- so hasStage(.grid), not .geometry, is the real "is
        // there nothing left to do" check here.
        guard !pipeline.hasStage(.grid), errors[index] == nil, !runningIndices.contains(index) else { return }
        JobScheduler.shared.request(document: document, simulationName: name, target: .geometryGeneration)
        // request() may have only queued this job behind another simulation's own in-flight run --
        // refresh again now (not just the pre-request call above) so the freshly-queued state is
        // shown immediately instead of a blank content area (see ProgressStatusView.State.queued).
        refreshDisplay()
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
        layerLoaders[index]?.cancel()
        layerLoaders[index] = nil
        layerCatalogs[index] = nil
        mergedDetailedPreview.remove(index)
        guard let document, index < document.config.simulations.count else { return }
        JobScheduler.shared.invalidate(document: document, simulationName: document.config.simulations[index].name,
                                        fromStage: .geometry)
    }

    /// Toggled from the "Show Grid" checkbox -- see showGridCheckbox's own doc comment for why this
    /// is per-simulation state, not a single shared flag. No separate fetch needed here any more --
    /// .geometryGeneration's own job always computes grid lines alongside the sliced board (see
    /// JobKind's own doc comment), so by the time this checkbox is even visible (only once geometry
    /// is already showing -- see refreshDisplay()), grid lines are already cached too.
    @objc private func toggleGridOverlay(_ sender: NSButton) {
        guard let currentIndex else { return }
        gridOverlayEnabled[currentIndex] = sender.state == .on
        refreshDisplay()
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

        if let detailed = pipeline.geometryPreview() {
            let preview: EMSGeometryPreview
            if let catalog = layerCatalogs[currentIndex] {
                if !mergedDetailedPreview.contains(currentIndex) {
                    catalog.mergeLoadedPreview(detailed)
                    mergedDetailedPreview.insert(currentIndex)
                    let loader = BoardLayerGeometryLoader(pipeline: pipeline, preview: catalog,
                                                           view: geometryView,
                                                           initiallyVisible: geometryView.visibleLayerNames)
                    layerLoaders[currentIndex] = loader
                    loader.start()
                }
                preview = catalog
            } else {
                preview = detailed
            }
            if geometryView.preview !== preview { geometryView.preview = preview }
            else { geometryView.refreshLoadedGeometry() }
            geometryView.showGrid = wantsGrid
            geometryView.isHidden = false
            progressStatus.setState(.hidden)
            showGridCheckbox.isHidden = false
        } else if let catalog = layerCatalogs[currentIndex] {
            if geometryView.preview !== catalog { geometryView.preview = catalog }
            geometryView.showGrid = false
            geometryView.isHidden = false
            progressStatus.setState(.hidden)
            showGridCheckbox.isHidden = true
        } else if let error = errors[currentIndex] {
            geometryView.isHidden = true
            progressStatus.setState(.error(error))
            showGridCheckbox.isHidden = true
        } else if runningIndices.contains(currentIndex) {
            geometryView.isHidden = true
            progressStatus.setState(.progress(status: "Processing Geometry…",
                                              fraction: progressFraction[currentIndex] ?? 0,
                                              timeEstimateText: timeEstimateText[currentIndex]
                                                  ?? TimeRemainingFormatter.string(secondsRemaining: nil)))
            showGridCheckbox.isHidden = true
        } else if JobScheduler.shared.job(document: document, simulationName: name,
                                          kind: .geometryGeneration)?.status == .queued {
            // A job exists for this simulation but the scheduler hasn't started it yet (waiting
            // behind another simulation's own in-flight run) -- see ProgressStatusView.State.queued's
            // own doc comment for why this is shown rather than a blank content area.
            geometryView.isHidden = true
            progressStatus.setState(.queued("Waiting to start…", currentJob: JobScheduler.shared.jobs.first?.progressStatusInfo))
            showGridCheckbox.isHidden = true
        } else {
            geometryView.isHidden = true
            progressStatus.setState(.hidden)
            showGridCheckbox.isHidden = true
        }
    }

    private func loadLayerCatalogIfNeeded(forSimulationIndex index: Int) {
        guard layerCatalogs[index] == nil, !loadingLayerCatalogs.contains(index),
              let document, let boardPath = document.config.kicadPcbPath else { return }
        loadingLayerCatalogs.insert(index)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let preview = try? KicadBoardBridge.layerCatalogPreview(forBoard: boardPath,
                                                                     wholeBoard: false)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingLayerCatalogs.remove(index)
                guard let preview else { return }
                self.layerCatalogs[index] = preview
                if self.currentIndex == index { self.refreshDisplay() }
            }
        }
    }

    /// Called from JobScheduler.shared's onChange notification -- reconciles this VC's own per-index
    /// runningIndices/errors/progress state (which refreshDisplay() actually reads) against the
    /// scheduler's real, authoritative job list, and fires onRunStateChanged/onProgressChanged/
    /// onRunFinished/onRunCancelled on the transitions those closures expect exactly once each,
    /// mirroring what the old direct-dispatch runStep()/stepFinished() pair used to do inline.
    private func syncFromScheduler() {
        guard let document else { return }
        for index in 0..<document.config.simulations.count {
            let name = document.config.simulations[index].name
            let pipeline = document.pipeline(forSimulationNamed: name)
            let job = JobScheduler.shared.job(document: document, simulationName: name, kind: .geometryGeneration)
            let wasRunning = runningIndices.contains(index)

            switch job?.status {
            case .running, .cancelling:
                if !wasRunning {
                    runningIndices.insert(index)
                    runStartTime[index] = Date()
                    onRunStateChanged?(index, true)
                    refreshDisplay()
                }
                if let progress = job?.progress {
                    progressReceived(progress, forSimulationIndex: index)
                }

            case .failed(let message):
                guard wasRunning else { continue }
                finishTracking(forSimulationIndex: index)
                errors[index] = message
                onRunFinished?(index, false)
                if let jobID = job?.id { JobScheduler.shared.dismiss(jobID: jobID) }
                refreshDisplay()

            case .queued, nil:
                guard wasRunning else { continue }
                finishTracking(forSimulationIndex: index)
                if pipeline.hasStage(.grid) {
                    onRunFinished?(index, true)
                } else {
                    // Cancelled, not failed -- the checkbox's own "Show Grid" state is left as-is
                    // (unlike the old quiet grid-only fetch's failure path, there's no already-shown
                    // geometry to protect here: a cancelled .geometryGeneration job never had one).
                    onRunCancelled?(index)
                }
                refreshDisplay()
            }
        }
        // Keeps the "Current Job: ..." sub-section (see ProgressStatusView's own doc comment) live
        // while this simulation's own job sits queued behind some *other* simulation's in-flight
        // run -- that other job's own progress ticks don't touch this VC's own runningIndices/
        // errors state at all, so nothing in the loop above would otherwise ever repaint it. Guarded
        // on !runningIndices.contains: when this VC's own job IS what's running, refreshDisplay()
        // there already reflects progressReceived()'s own *animated* update above -- redundantly
        // calling it again here (non-animated) would just cancel that animation mid-flight.
        if let currentIndex, !runningIndices.contains(currentIndex), errors[currentIndex] == nil {
            refreshDisplay()
        }
    }

    private func finishTracking(forSimulationIndex index: Int) {
        runningIndices.remove(index)
        progressFraction[index] = nil
        runStartTime[index] = nil
        timeEstimateText[index] = nil
        onRunStateChanged?(index, false)
    }

    /// Common handler for every EMSPipelineProgress report from this simulation's own
    /// .geometryGeneration job -- relayed outward via onProgressChanged (for the source-list row)
    /// and, if this is the currently-shown simulation, applied to this VC's own progress bar/time
    /// estimate too.
    private func progressReceived(_ progress: EMSPipelineProgress, forSimulationIndex index: Int) {
        progressFraction[index] = progress.fraction
        onProgressChanged?(index, progress)
        // Simple linear extrapolation from elapsed time and how far through this run we are.
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
            progressStatus.setState(.progress(status: "Processing Geometry…",
                                              fraction: progress.fraction,
                                              timeEstimateText: estimateText), animated: true)
        }
    }
}
