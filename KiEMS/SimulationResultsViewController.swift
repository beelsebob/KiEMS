import Cocoa
import CopperUtils
import RememberRemember

/// NSScrollView positions a flipped document view from its top edge when its content is shorter
/// than the viewport. The charts retain their own native (non-flipped) drawing coordinates; only
/// this layout container needs to be flipped.
private final class ResultsDocumentStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// A compact disclosure row for one results graph. Keeping the graph as an arranged subview means
/// hiding it also collapses its fixed chart height, instead of leaving a blank 220-point hole.
private final class DisclosureGraphView: NSStackView {
    private let disclosureButton: NSButton
    private let titleLabel: NSTextField
    private let graph: NSView

    init(title: String, graph: NSView) {
        disclosureButton = NSButton(title: "", target: nil, action: nil)
        titleLabel = NSTextField(labelWithString: title)
        self.graph = graph
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        spacing = 6

        disclosureButton.setButtonType(.onOff)
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.state = .on
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleGraph)
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        let header = NSStackView(views: [disclosureButton, titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4

        addArrangedSubview(header)
        addArrangedSubview(graph)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            graph.leadingAnchor.constraint(equalTo: leadingAnchor),
            graph.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleGraph() {
        graph.isHidden = disclosureButton.state != .on
    }
}

/// Which group of charts is currently shown -- an NSSegmentedControl lets the user switch between
/// them; only categories with at least one section to show ever appear (see showCategories).
private enum ResultsCategory: CaseIterable {
    case sParameters
    case eyeDiagrams
    case impedance
    case smith
    case traceDelays
    case probes

    var title: String {
        switch self {
        case .sParameters: return "S-Parameters"
        case .eyeDiagrams: return "Eye diagrams"
        case .impedance: return "Impedance"
        case .smith: return "Smith"
        case .traceDelays: return "Trace Delays"
        case .probes: return "Probes"
        }
    }
}

/// Content for a simulation's "Simulation Results" sub-entry, selected via
/// SimulationListViewController's outline view. Runs the shared per-simulation pipeline
/// (Document.pipeline(forSimulationNamed:), EMSSimulationPipelineBridge) up through its Results
/// stage in the background the first time a given simulation's Results entry is shown -- the same
/// run/error/spinner pattern GeometryViewController uses, just one stage further down the pipeline
/// (and, since it includes a real FDTD run with no progress callback, potentially far slower:
/// minutes to hours, not seconds). If this simulation's Geometry entry was already shown first, the
/// pipeline reuses that same sliced board/grid lines rather than redoing them. The pipeline itself
/// caches the built results; this view controller only tracks its own in-flight/error state, since
/// "is the results step running" and "did it just fail" aren't things the shared pipeline remembers
/// on its own.
final class SimulationResultsViewController: NSViewController {
    private weak var document: Document?

    private let progressStatus = ProgressStatusView()
    /// Shown left of progressStatus's own progress bar only while EMSPipelineProgress.duringExcitation
    /// is true (the excitation pulse is still actively being injected, as opposed to the run just
    /// observing decay afterward) -- see that property's own doc comment.
    private let excitationIcon = NSImageView()
    private let energyHistoryChart = MultiCurveLineChartView()
    private let categoryControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let stack = ResultsDocumentStackView()

    private var progressGroupToEnergyChartConstraint: NSLayoutConstraint!

    private var errors: [Int: String] = [:]
    private var runningIndices: Set<Int> = []
    // Latest known progress per simulation, from this VC's own in-flight ensureStage: call -- see
    // GeometryViewController's identical progressFraction field for why refreshDisplay() needs this
    // rather than relying solely on the live progress callback.
    private var latestProgress: [Int: EMSPipelineProgress] = [:]
    // When the *current phase* of a simulation's in-flight run began -- the basis for the elapsed-
    // time/fraction extrapolation behind progressStatus's own time-estimate label (see
    // progressReceived()). Reset
    // whenever the reported phase changes, not just once at the start of the whole run: `fraction`
    // itself restarts from 0 at the geometry -> simulation boundary (see EMSPipelineProgressPhase's
    // own doc comment), so elapsed time has to restart its extrapolation basis there too, or the
    // estimate would be computed against the wrong phase's elapsed time.
    private var phaseStartTime: [Int: Date] = [:]
    private var lastReportedPhase: [Int: EMSPipelineProgressPhase] = [:]
    // Latest known time-remaining text per simulation, mirroring latestProgress's own "so
    // refreshDisplay() can restore state on re-selection" role.
    private var timeEstimateText: [Int: String] = [:]
    private struct EnergyHistorySample {
        let timeNanoseconds: Double
        let relativeEnergyDB: Double
    }
    /// One live excitation at a time per simulation. A later port starts its physical time at zero,
    /// so its setup report clears the previous port's curve rather than joining unrelated runs.
    private var energyHistory: [Int: [EnergyHistorySample]] = [:]
    private var energyHistoryFullRunNanoseconds: [Int: Double] = [:]
    private var energyHistoryExcitationBands: [Int: ChartXIntensityBand] = [:]
    private var currentIndex: Int?
    private var availableCategories: [ResultsCategory] = []
    private var selectedCategory: ResultsCategory = .sParameters

    /// Fired with every EMSPipelineProgress this VC's own in-flight ensureStage: call reports (both
    /// .geometry-phase, on the way to the FDTD run, and .simulation-phase, for the run itself), so
    /// DocumentWindowController can relay each to SimulationListViewController's own "Geometry"/
    /// "Simulation Results" row -- see GeometryViewController.onProgressChanged's identical doc
    /// comment for the phase-based row split.
    var onProgressChanged: ((Int, EMSPipelineProgress) -> Void)?

    /// Fired once this VC's own ensureStage:.results run finishes for a given simulation, with the
    /// EMSPipelineProgressPhase it had reached (from the last progress report before finishing) and
    /// whether it succeeded. The phase matters because this run computes geometry as an unavoidable
    /// first step (see EMSPipelineProgressPhase's own doc comment) -- a failure can originate in
    /// either stage, and DocumentWindowController needs to know which one to attribute the outcome
    /// to (the "Geometry" row vs the "Simulation Results" row). Reaching .simulation at all means
    /// geometry itself already succeeded, regardless of how this run ultimately finishes.
    var onRunFinished: ((Int, EMSPipelineProgressPhase, Bool) -> Void)?

    /// Fired when a simulation's results job was cancelled (via the Jobs window) rather than
    /// finishing with a real error -- see GeometryViewController.onRunCancelled's identical doc
    /// comment. Carries the phase reached, same as onRunFinished, so DocumentWindowController resets
    /// the right row (or both, if cancellation happened mid-.simulation -- geometry itself did
    /// genuinely finish first, so that row should still flip to "completed", not reset).
    var onRunCancelled: ((Int, EMSPipelineProgressPhase) -> Void)?

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

        progressStatus.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressStatus)

        excitationIcon.image = NSImage(systemSymbolName: "waveform.path.ecg.rectangle",
                                        accessibilityDescription: "Exciting")
        excitationIcon.contentTintColor = .systemOrange
        excitationIcon.isHidden = true
        excitationIcon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(excitationIcon)

        energyHistoryChart.configure(yAxisLabel: "Relative energy [dB]")
        energyHistoryChart.isHidden = true
        container.addSubview(energyHistoryChart)

        categoryControl.segmentStyle = .texturedRounded
        categoryControl.target = self
        categoryControl.action = #selector(categoryChanged)
        categoryControl.translatesAutoresizingMaskIntoConstraints = false
        categoryControl.isHidden = true
        container.addSubview(categoryControl)

        // NSStackView.alignment is a cross-axis *guide* attribute (.leading/.trailing/.centerX for
        // a vertical stack) -- there's no "fill" value that makes arranged subviews span the
        // stack's full width the way UIStackView's .fill distribution would. Each section's width
        // is instead pinned explicitly in rebuildStack(), leaving every arranged subview's width
        // fully determined rather than silently unconstrained.
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isHidden = true
        container.addSubview(scrollView)

        let preferredEnergyChartWidth = energyHistoryChart.widthAnchor.constraint(equalToConstant: 520)
        preferredEnergyChartWidth.priority = .defaultHigh
        let progressGroupGuide = NSLayoutGuide()
        container.addLayoutGuide(progressGroupGuide)
        progressGroupToEnergyChartConstraint = progressGroupGuide.bottomAnchor.constraint(
            equalTo: energyHistoryChart.bottomAnchor)
        NSLayoutConstraint.activate([
            categoryControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            categoryControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: categoryControl.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            progressStatus.topAnchor.constraint(equalTo: container.topAnchor),
            progressStatus.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressStatus.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressStatus.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            // When the chart is visible this guide centres the complete progress composition,
            // rather than the status rows alone with the chart hanging below the midpoint.
            progressGroupGuide.topAnchor.constraint(equalTo: progressStatus.contentTopAnchor),
            progressGroupGuide.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            excitationIcon.trailingAnchor.constraint(equalTo: progressStatus.progressBar.leadingAnchor, constant: -8),
            excitationIcon.centerYAnchor.constraint(equalTo: progressStatus.progressBar.centerYAnchor),
            excitationIcon.widthAnchor.constraint(equalToConstant: 16),
            excitationIcon.heightAnchor.constraint(equalToConstant: 16),

            energyHistoryChart.topAnchor.constraint(equalTo: progressStatus.timeEstimateLabel.bottomAnchor,
                                                    constant: 12),
            energyHistoryChart.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            energyHistoryChart.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            energyHistoryChart.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            preferredEnergyChartWidth,
        ])

        view = container
    }

    /// Called by DocumentWindowController whenever the user selects a simulation's "Simulation
    /// Results" sub-entry (including re-selecting one already showing). Shows a cached result or
    /// error immediately if there is one; otherwise kicks off the full pipeline in the background --
    /// unlike Geometry, there is no separate "Run" button: selecting the tab is the trigger.
    func showResults(forSimulationIndex index: Int) {
        currentIndex = index
        refreshDisplay()

        guard let document, index < document.config.simulations.count else { return }
        let name = document.config.simulations[index].name
        let pipeline = document.pipeline(forSimulationNamed: name)
        guard !pipeline.hasStage(.results), errors[index] == nil, !runningIndices.contains(index) else { return }
        JobScheduler.shared.request(document: document, simulationName: name, target: .simulation)
        // request() may have only queued this job behind another simulation's own in-flight run --
        // refresh again now (not just the pre-request call above) so the freshly-queued state is
        // shown immediately instead of a blank content area (see ProgressStatusView.State.queued).
        refreshDisplay(animated: false)
    }

    /// Called by DocumentWindowController whenever something that would change this simulation's
    /// results changes -- either the same edits that invalidate GeometryViewController's own cache
    /// (hull-padding/via/ground-net edits, involved-nets membership/impedance/plane/width changes,
    /// which also invalidate geometry) or an FDTD-only parameter change (SimulationPropertiesViewController.
    /// onFDTDParametersChanged) that leaves the sliced geometry/grid untouched -- so a stale cached
    /// result (or error) from before the edit doesn't keep being shown. Deliberately doesn't re-run
    /// immediately: just invalidates the shared pipeline's cache from the Results stage onward
    /// (Geometry and grid lines stay valid and don't get recomputed) and clears this VC's own error,
    /// so the next explicit Results selection is what triggers the real re-run.
    func invalidateCache(forSimulationIndex index: Int) {
        errors[index] = nil
        guard let document, index < document.config.simulations.count else { return }
        JobScheduler.shared.invalidate(document: document, simulationName: document.config.simulations[index].name,
                                        fromStage: .results)
    }

    /// Eye rate affects only PRBS post-analysis. Keep the completed FDTD/S-parameter cache and
    /// rebuild the lightweight results preview at the new unit interval.
    func eyeBitRateChanged(forSimulationIndex index: Int, bitRate: Double) {
        guard let document, index < document.config.simulations.count else { return }
        document.pipeline(forSimulationNamed: document.config.simulations[index].name).updateEyeBitRate(bitRate)
        if currentIndex == index {
            refreshDisplay()
        }
    }

    private func updateProgressGroupCentering() {
        let includesChart = !energyHistoryChart.isHidden
        progressGroupToEnergyChartConstraint.isActive = false
        if includesChart {
            progressStatus.setUsesDefaultVerticalCentering(false)
            progressGroupToEnergyChartConstraint.isActive = true
        } else {
            progressStatus.setUsesDefaultVerticalCentering(true)
        }
    }

    /// `animated` smooths the progress bar's own doubleValue transitions --
    /// meant for live ticks from progressReceived() (small, incremental deltas within the same
    /// simulation), not for the other call sites (selection changes, run start/finish), where the
    /// value can jump to represent an unrelated simulation's own progress and animating that jump
    /// would be misleading motion, not a smooth update.
    private func refreshDisplay(animated: Bool = false) {
        guard let currentIndex, let document, currentIndex < document.config.simulations.count else { return }
        defer { updateProgressGroupCentering() }
        let name = document.config.simulations[currentIndex].name
        let pipeline = document.pipeline(forSimulationNamed: name)
        if let preview = pipeline.resultsPreview() {
            // These default to visible (NSControl's own isHidden default) until a run's own
            // running/error/idle branch below first sets them -- a simulation whose results are
            // already cached before this VC's very first refreshDisplay() call (e.g. from a
            // previous session) would otherwise skip that and show them at their AppKit defaults,
            // stacked on top of the just-shown charts.
            excitationIcon.isHidden = true
            energyHistoryChart.isHidden = true
            showCategories(for: preview)
        } else if let error = errors[currentIndex] {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            progressStatus.setState(.error(error))
            excitationIcon.isHidden = true
            energyHistoryChart.isHidden = true
        } else if runningIndices.contains(currentIndex) {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            let progress = latestProgress[currentIndex]
            let isSettingUp = progress?.phase == .settingUp
            let statusText: String
            switch progress?.phase {
            case .simulation:
                statusText = "Running simulation…"
            case .settingUp:
                statusText = "Setting up Simulation…"
            default:
                statusText = "Building geometry…"
            }
            let netStatus = progress?.excitedNetName.map {
                ProgressStatusView.NetStatus(prefix: "\(name) – Exciting ", netName: $0)
            }
            // .settingUp has no fraction of any kind to show -- openEMS gives no progress hook into
            // its own setup call at all (see EMSPipelineProgressPhase's own doc comment), and guessing
            // a duration from mesh size turned out to not be worth the false confidence a countdown
            // implies. fraction nil => an animated indeterminate bar; time-estimate text nil => that
            // row is hidden instead of guessing.
            progressStatus.setState(.progress(
                status: statusText,
                netStatus: netStatus,
                fraction: isSettingUp ? nil : (progress?.fraction ?? 0),
                timeEstimateText: isSettingUp ? nil
                    : (timeEstimateText[currentIndex] ?? TimeRemainingFormatter.string(secondsRemaining: nil))),
                animated: animated)
            excitationIcon.isHidden = !(progress?.phase == .simulation && (progress?.duringExcitation ?? false))
            if isSettingUp {
                energyHistoryChart.isHidden = true
            } else if let progress, progress.phase == .simulation {
                updateEnergyHistoryChart(forSimulationIndex: currentIndex)
            } else {
                energyHistoryChart.isHidden = true
            }
        } else if (JobScheduler.shared.job(document: document, simulationName: name, kind: .simulation)
                ?? JobScheduler.shared.job(document: document, simulationName: name,
                                           kind: .geometryGeneration))?.status == .queued {
            // A job exists for this simulation but the scheduler hasn't started it yet (waiting
            // behind another simulation's own in-flight run) -- see ProgressStatusView.State.queued's
            // own doc comment for why this is shown rather than a blank content area.
            categoryControl.isHidden = true
            scrollView.isHidden = true
            progressStatus.setState(.queued("Waiting to start…", currentJob: JobScheduler.shared.jobs.first?.progressStatusInfo))
            excitationIcon.isHidden = true
            energyHistoryChart.isHidden = true
        } else {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            progressStatus.setState(.hidden)
            excitationIcon.isHidden = true
            energyHistoryChart.isHidden = true
        }
    }

    /// Called from JobScheduler.shared's onChange notification -- see
    /// GeometryViewController.syncFromScheduler()'s identical-in-spirit doc comment. Watches this
    /// simulation's own .geometryGeneration job while it's still the active prerequisite, then its
    /// .simulation job once that one starts running -- both report through this same progressReceived
    /// (a job's own `progress.phase` already distinguishes them, exactly as when a single combined
    /// ensureStage:.results call used to report both phases itself).
    private func syncFromScheduler() {
        guard let document else { return }
        for index in 0..<document.config.simulations.count {
            let name = document.config.simulations[index].name
            let pipeline = document.pipeline(forSimulationNamed: name)
            let geometryJob = JobScheduler.shared.job(document: document, simulationName: name, kind: .geometryGeneration)
            let simulationJob = JobScheduler.shared.job(document: document, simulationName: name, kind: .simulation)
            let activeJob = simulationJob ?? geometryJob
            let wasRunning = runningIndices.contains(index)

            switch activeJob?.status {
            case .running, .cancelling:
                if !wasRunning {
                    runningIndices.insert(index)
                    refreshDisplay()
                }
                if let progress = activeJob?.progress {
                    progressReceived(progress, forSimulationIndex: index)
                }

            case .failed(let message):
                guard wasRunning else { continue }
                let reachedPhase = latestProgress[index]?.phase ?? .geometry
                finishTracking(forSimulationIndex: index)
                errors[index] = message
                onRunFinished?(index, reachedPhase, false)
                if let jobID = activeJob?.id { JobScheduler.shared.dismiss(jobID: jobID) }
                refreshDisplay()

            case .queued, nil:
                guard wasRunning else { continue }
                let reachedPhase = latestProgress[index]?.phase ?? .geometry
                finishTracking(forSimulationIndex: index)
                if pipeline.hasStage(.results) {
                    onRunFinished?(index, .simulation, true)
                } else {
                    onRunCancelled?(index, reachedPhase)
                }
                refreshDisplay()
            }
        }
        // Keeps the "Current Job: ..." sub-section (see ProgressStatusView's own doc comment) live
        // while this simulation's own job sits queued behind some *other* simulation's in-flight
        // run -- see GeometryViewController.syncFromScheduler()'s identical trailing check for why
        // this is scoped to !runningIndices.contains (avoiding cancelling progressReceived()'s own
        // animated update above when this VC's own job is the one actually running).
        if let currentIndex, !runningIndices.contains(currentIndex), errors[currentIndex] == nil {
            refreshDisplay()
        }
    }

    private func finishTracking(forSimulationIndex index: Int) {
        runningIndices.remove(index)
        latestProgress[index] = nil
        lastReportedPhase[index] = nil
        phaseStartTime[index] = nil
        timeEstimateText[index] = nil
    }

    /// Common handler for every EMSPipelineProgress report from this simulation's own
    /// .geometryGeneration/.simulation jobs -- relayed outward via onProgressChanged (for the
    /// source-list row) and, if this is the currently-shown simulation, applied to this VC's own
    /// progress bar/time estimate and energy-history chart too.
    private func progressReceived(_ progress: EMSPipelineProgress, forSimulationIndex index: Int) {
        latestProgress[index] = progress
        if progress.phase == .settingUp {
            // Each excited port gets its own FDTD run and its own time origin. Do not connect the
            // tail of the previous excitation's energy curve to the start of this one.
            energyHistory[index] = []
            energyHistoryFullRunNanoseconds[index] = nil
            energyHistoryExcitationBands[index] = nil
        } else if progress.phase == .simulation {
            recordEnergyHistory(progress, forSimulationIndex: index)
        }
        onProgressChanged?(index, progress)
        let name = simulationName(forIndex: index)
        let percent = Int((progress.fraction * 100).rounded())
        switch progress.phase {
        case .simulation:
            Cu.logInfo("[\(name)] Simulation: \(percent)% (energy ~\(String(format: "%.2e", progress.absoluteEnergy))"
                + ", \(String(format: "%.1f", progress.energyChangeDB))"
                + "/\(String(format: "%.1f", progress.targetEnergyChangeDB)) dB)")
        case .settingUp:
            Cu.logInfo("[\(name)] Setting up simulation…")
        default:
            Cu.logInfo("[\(name)] Geometry: \(percent)%")
        }
        // See phaseStartTime's own doc comment for why this resets on every phase change, not just
        // once per run. A phase change is rendered as a non-animated jump (refreshDisplay below,
        // animated: !phaseJustChanged) rather than an animated slide -- without that, the very next
        // update would visibly slide from wherever the *previous* phase left off (e.g. the Geometry
        // bar sitting at 100%) down to this new phase's own starting point, transiently reading as
        // some confusing intermediate "half complete" value instead of genuinely restarting from
        // scratch the moment the new phase begins.
        var phaseJustChanged = false
        if lastReportedPhase[index] != progress.phase {
            phaseJustChanged = true
            lastReportedPhase[index] = progress.phase
            phaseStartTime[index] = Date()
        }
        // .settingUp has no fraction to extrapolate a remaining time from at all (see
        // EMSPipelineProgressPhase's own doc comment) -- refreshDisplay() shows a plain indeterminate
        // bar and no time-estimate text for it instead, so there's nothing useful to compute here.
        if progress.phase != .settingUp {
            let secondsRemaining: Double?
            if let start = phaseStartTime[index], progress.fraction > 0 {
                let elapsed = Date().timeIntervalSince(start)
                secondsRemaining = max(0, elapsed / progress.fraction - elapsed)
            } else {
                secondsRemaining = nil
            }
            timeEstimateText[index] = TimeRemainingFormatter.string(secondsRemaining: secondsRemaining)
        }
        if currentIndex == index, runningIndices.contains(index) {
            refreshDisplay(animated: !phaseJustChanged)
        }
    }

    private func recordEnergyHistory(_ progress: EMSPipelineProgress, forSimulationIndex index: Int) {
        let timeNanoseconds = progress.simulationTimeSeconds * 1e9
        guard timeNanoseconds.isFinite, timeNanoseconds >= 0, progress.energyChangeDB.isFinite else { return }

        // Copper reports the positive magnitude of the decay from peak energy. Negating it gives
        // the conventional logarithmic relative-energy scale: 0 dB at the peak, falling to -60 dB.
        let relativeEnergyDB = max(-60, min(0, -progress.energyChangeDB))
        if progress.plannedSimulationTimeSeconds.isFinite, progress.plannedSimulationTimeSeconds > 0 {
            energyHistoryFullRunNanoseconds[index] = progress.plannedSimulationTimeSeconds * 1e9
        }
        if progress.excitationEndTimeSeconds.isFinite, progress.excitationEndTimeSeconds > 0,
           progress.excitationF0Hz.isFinite, progress.excitationFcHz.isFinite,
           progress.excitationFcHz > 0 {
            let sampleCount = 512
            let duration = progress.excitationEndTimeSeconds
            let centreTime = 9 / (2 * Double.pi * progress.excitationFcHz)
            let magnitudes = (0..<sampleCount).map { sampleIndex -> Double in
                guard sampleIndex > 0 else { return 0 }
                let time = duration * Double(sampleIndex) / Double(sampleCount - 1)
                let carrier = cos(2 * Double.pi * progress.excitationF0Hz * (time - centreTime))
                let envelopePosition = 2 * Double.pi * progress.excitationFcHz * time / 3 - 3
                return abs(carrier * exp(-envelopePosition * envelopePosition))
            }
            energyHistoryExcitationBands[index] = ChartXIntensityBand(
                startX: 0, endX: duration * 1e9, intensities: magnitudes)
        }
        var samples = energyHistory[index] ?? []
        let sample = EnergyHistorySample(timeNanoseconds: timeNanoseconds, relativeEnergyDB: relativeEnergyDB)
        if let last = samples.last {
            if timeNanoseconds < last.timeNanoseconds {
                // Defensive fallback for a new port whose setup update was coalesced by the job
                // scheduler: physical time restarting still unambiguously marks a new run.
                samples = [sample]
            } else if timeNanoseconds == last.timeNanoseconds {
                samples[samples.count - 1] = sample
            } else {
                samples.append(sample)
            }
        } else {
            samples.append(sample)
        }
        energyHistory[index] = samples
    }

    private func updateEnergyHistoryChart(forSimulationIndex index: Int) {
        let samples = energyHistory[index] ?? []
        let times = samples.map(\.timeNanoseconds)
        let rawValues = samples.map(\.relativeEnergyDB)
        let observedTimeRange = max(0, (times.last ?? 0) - (times.first ?? 0))
        let fullTimeRange = energyHistoryFullRunNanoseconds[index] ?? observedTimeRange
        let averagedValues = Self.centredMovingAverage(
            xValues: times, values: rawValues, windowWidth: fullTimeRange * 0.05)
        energyHistoryChart.setStyledCurves(
            xValuesGHz: times,
            curves: [
                ChartCurve(label: "Raw energy", values: rawValues, lineWidth: 0.5),
                ChartCurve(label: "Rolling Average", values: averagedValues),
            ],
            minRange: (-60, 0),
            xAxisMinRange: energyHistoryFullRunNanoseconds[index].map { (min: 0, max: $0) },
            xIntensityBand: energyHistoryExcitationBands[index],
            xAxisScale: .linear,
            xAxisLabel: "Simulation time [ns]")
        energyHistoryChart.isHidden = samples.isEmpty
    }

    /// Centred moving average over a window measured in X-axis units, rather than a fixed number
    /// of samples. At either boundary, preserve a full symmetric sample window by edge-padding:
    /// virtual samples before/after the series take the first/final value respectively. Thus the
    /// filter remains centred instead of becoming progressively one-sided near a live edge.
    private static func centredMovingAverage(xValues: [Double], values: [Double],
                                              windowWidth: Double) -> [Double] {
        guard !values.isEmpty, xValues.count == values.count,
              windowWidth.isFinite, windowWidth > 0 else { return values }
        var prefixSums = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices {
            prefixSums[index + 1] = prefixSums[index] + values[index]
        }

        let halfWidth = windowWidth / 2
        var lowerBound = values.startIndex
        var upperBound = values.startIndex
        return values.indices.map { index in
            let windowMinimum = xValues[index] - halfWidth
            let windowMaximum = xValues[index] + halfWidth
            while lowerBound < values.endIndex, xValues[lowerBound] < windowMinimum {
                lowerBound += 1
            }
            upperBound = max(upperBound, index)
            while upperBound < values.endIndex, xValues[upperBound] <= windowMaximum {
                upperBound += 1
            }
            let actualCount = upperBound - lowerBound
            guard actualCount > 0 else { return values[index] }

            let leftCount = index - lowerBound
            let rightCount = upperBound - index - 1
            var paddedLeftCount = 0
            var paddedRightCount = 0
            if windowMinimum < xValues[values.startIndex] {
                paddedLeftCount = max(0, rightCount - leftCount)
            }
            if windowMaximum > xValues[values.index(before: values.endIndex)] {
                paddedRightCount = max(0, leftCount - rightCount)
            }

            var sum = prefixSums[upperBound] - prefixSums[lowerBound]
            sum += Double(paddedLeftCount) * values[values.startIndex]
            sum += Double(paddedRightCount) * values[values.index(before: values.endIndex)]
            return sum / Double(actualCount + paddedLeftCount + paddedRightCount)
        }
    }

    private func simulationName(forIndex index: Int) -> String {
        guard let document, index < document.config.simulations.count else { return "simulation \(index)" }
        return document.config.simulations[index].name
    }


    // MARK: - Category/chart building

    private func showCategories(for preview: EMSResultsPreview) {
        var categories: [ResultsCategory] = []
        let hasDifferentialSParameters = preview.diffPairs.contains { $0.sdd11Db != nil || $0.sdd21Db != nil }
        let hasDifferentialImpedance = preview.diffPairs.contains {
            $0.impedanceMagnitudeOhm != nil && $0.impedanceAngleDeg != nil
        }
        let hasDifferentialDelay = preview.diffPairs.contains { $0.nDelayNs != nil || $0.pDelayNs != nil }
        if !preview.sParamSets.isEmpty || hasDifferentialSParameters { categories.append(.sParameters) }
        if !preview.eyeDiagrams.isEmpty { categories.append(.eyeDiagrams) }
        if !preview.netImpedances.isEmpty || hasDifferentialImpedance { categories.append(.impedance) }
        if !preview.smithCharts.isEmpty { categories.append(.smith) }
        if !preview.traces.isEmpty || hasDifferentialDelay { categories.append(.traceDelays) }
        if !preview.probes.isEmpty { categories.append(.probes) }
        availableCategories = categories

        guard !categories.isEmpty else {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            progressStatus.setState(.message("No results to display."))
            return
        }

        categoryControl.isHidden = false
        scrollView.isHidden = false
        progressStatus.setState(.hidden)

        categoryControl.segmentCount = categories.count
        for (i, category) in categories.enumerated() {
            categoryControl.setLabel(category.title, forSegment: i)
            categoryControl.setWidth(0, forSegment: i)
        }
        if !categories.contains(where: { $0.title == selectedCategory.title }) {
            selectedCategory = categories[0]
        }
        if let selectedIndex = categories.firstIndex(where: { $0.title == selectedCategory.title }) {
            categoryControl.selectedSegment = selectedIndex
        }

        rebuildStack(for: preview)
    }

    @objc private func categoryChanged() {
        guard categoryControl.selectedSegment >= 0, categoryControl.selectedSegment < availableCategories.count,
              let currentIndex, let document, currentIndex < document.config.simulations.count,
              let preview = document.pipeline(forSimulationNamed: document.config.simulations[currentIndex].name)
                  .resultsPreview() else { return }
        selectedCategory = availableCategories[categoryControl.selectedSegment]
        rebuildStack(for: preview)
    }

    private func rebuildStack(for preview: EMSResultsPreview) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for section in sections(for: selectedCategory, preview: preview) {
            stack.addArrangedSubview(section)
            // See stack.alignment's own comment -- width isn't propagated automatically.
            NSLayoutConstraint.activate([
                section.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
                section.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            ])
        }
    }

    private func sections(for category: ResultsCategory, preview: EMSResultsPreview) -> [NSView] {
        let freqGHz = preview.frequenciesGHz.map(\.doubleValue)

        switch category {
        case .sParameters:
            var sections: [NSView] = preview.diffPairs.compactMap { pair in
                var curves: [ChartCurve] = []
                if let sdd11 = pair.sdd11Db {
                    curves.append(ChartCurve(label: "Returned to Source", values: sdd11.map(\.doubleValue),
                                             lineWidth: 0.5))
                }
                if let sdd21 = pair.sdd21Db {
                    curves.append(ChartCurve(label: "Received", values: sdd21.map(\.doubleValue),
                                             lineWidth: 1.5, emphasized: true))
                }
                guard !curves.isEmpty else { return nil }
                let chart = MultiCurveLineChartView()
                chart.configure(yAxisLabel: "Magnitude (dB)", showsLabel: false)
                // Matches postprocess.cpp's own renderDiffPairSParams ylim convention.
                chart.setStyledCurves(xValuesGHz: freqGHz, curves: curves, minRange: (-60, 5))
                return makeSection(title: pair.name, graphs: [("Magnitude (dB)", chart)])
            }
            sections += preview.sParamSets.map { set in
                let magChart = MultiCurveLineChartView()
                magChart.configure(yAxisLabel: "Magnitude (dB)", showsLabel: false)
                // Matches postprocess.cpp's own renderSParams ylim convention: always show at least
                // -60..5dB, expanding further only if the data genuinely needs more room. Without
                // this, a single numerically-unstable outlier point (typical near the edges of the
                // excitation's frequency band, where the incident wave's own spectrum is weak enough
                // that reflected/incident stops being a stable ratio) can dominate the auto-scaled
                // range and visually flatten the physically meaningful part of the curve.
                let magnitudeCurves = set.curves.map { curve -> ChartCurve in
                    if curve.outputPort == set.excitedPort {
                        return ChartCurve(label: "Returned to Source", values: curve.magnitudeDb.map(\.doubleValue),
                                          lineWidth: 0.5)
                    }
                    let label = curve.isReceived
                        ? curve.label.replacingOccurrences(of: "Response at ", with: "Received at ")
                        : curve.label
                    return ChartCurve(label: label, values: curve.magnitudeDb.map(\.doubleValue),
                                      lineWidth: curve.isReceived ? 1.5 : 0.5,
                                      emphasized: curve.isReceived)
                }
                magChart.setStyledCurves(xValuesGHz: freqGHz, curves: magnitudeCurves,
                                         minRange: (-60, 5))

                let phaseChart = MultiCurveLineChartView()
                phaseChart.configure(yAxisLabel: "Phase (°)", showsLabel: false)
                let phaseCurves = set.curves.map { curve -> ChartCurve in
                    if curve.outputPort == set.excitedPort {
                        return ChartCurve(label: "Returned to Source", values: curve.phaseDeg.map(\.doubleValue),
                                          lineWidth: 0.5)
                    }
                    let label = curve.isReceived
                        ? curve.label.replacingOccurrences(of: "Response at ", with: "Received at ")
                        : curve.label
                    return ChartCurve(label: label, values: curve.phaseDeg.map(\.doubleValue),
                                      lineWidth: curve.isReceived ? 1.5 : 0.5,
                                      emphasized: curve.isReceived)
                }
                phaseChart.setStyledCurves(xValuesGHz: freqGHz, curves: phaseCurves)

                return makeSection(
                    title: "Excited Port: \(portDisplayName(index: set.excitedPort, preview: preview))",
                    graphs: [("Magnitude (dB)", magChart), ("Phase (°)", phaseChart)])
            }
            return sections

        case .eyeDiagrams:
            // Differential eyes first; stable within each group.
            let eyes = preview.eyeDiagrams.filter(\.isDifferential) + preview.eyeDiagrams.filter { !$0.isDifferential }
            return eyes.map { eye in
                let chart = EyeDiagramView()
                chart.setData(timeUI: eye.timeUI.map(\.doubleValue),
                              traces: eye.traces.map { $0.map(\.doubleValue) })
                let kind = eye.isDifferential ? "Differential received signal" : "Received signal"
                let rate = String(format: "%.4g Gb/s", eye.bitRateGbps)
                return makeSection(title: "\(eye.name) — \(kind), \(rate)", graphs: [("Eye Diagram", chart)])
            }

        case .impedance:
            var sections: [NSView] = preview.diffPairs.compactMap { pair in
                guard let mag = pair.impedanceMagnitudeOhm, let angle = pair.impedanceAngleDeg else { return nil }
                let magnitudeChart = MultiCurveLineChartView()
                magnitudeChart.configure(yAxisLabel: "Magnitude (Ω)", showsLabel: false)
                // Differential impedance uses the wider 0...200Ω default from postprocess.cpp.
                magnitudeChart.setCurves(
                    xValuesGHz: freqGHz,
                    curves: [(label: "|Z diff|", values: mag.map(\.doubleValue))],
                    minRange: (0, 200), xAxisLabel: nil)

                let phaseChart = MultiCurveLineChartView()
                phaseChart.configure(yAxisLabel: "Phase (°)", showsLabel: false)
                phaseChart.setCurves(
                    xValuesGHz: freqGHz,
                    curves: [(label: "Phase", values: angle.map(\.doubleValue))],
                    minRange: (-90, 90))

                return makeSection(title: pair.name,
                                   graphs: [("Magnitude (Ω)", magnitudeChart), ("Phase (°)", phaseChart)])
            }
            // Per net (a direct characteristic-impedance measurement from one or more non-loading
            // trace probes -- see EMSResultsNetImpedance's own doc comment), not per absorbing port
            // -- an average line, a shaded min/max band across that net's own probes, and each
            // probe's own curve drawn thin underneath.
            sections += preview.netImpedances.map { netImpedance in
                let probeMagnitudes = netImpedance.probes.map { $0.magnitudeOhm.map(\.doubleValue) }
                let probeAngles = netImpedance.probes.map { $0.angleDeg.map(\.doubleValue) }
                let probeLabels = netImpedance.probes.indices.map { "Probe \($0 + 1)" }

                let magnitudeChart = MultiCurveLineChartView()
                magnitudeChart.configure(yAxisLabel: "Magnitude (Ω)", showsLabel: false)
                let magStats = Self.averageAndBand(of: probeMagnitudes, count: freqGHz.count)
                magnitudeChart.setBandedCurves(
                    xValuesGHz: freqGHz,
                    probeCurves: zip(probeLabels, probeMagnitudes).map { ($0, $1) },
                    averageLabel: "Average |Z|", average: magStats.average, band: magStats.band,
                    minRange: (0, 100), xAxisLabel: nil)

                let angleChart = MultiCurveLineChartView()
                angleChart.configure(yAxisLabel: "Phase (°)", showsLabel: false)
                let angleStats = Self.averageAndBand(of: probeAngles, count: freqGHz.count)
                angleChart.setBandedCurves(
                    xValuesGHz: freqGHz,
                    probeCurves: zip(probeLabels, probeAngles).map { ($0, $1) },
                    averageLabel: "Average arg(Z)", average: angleStats.average, band: angleStats.band,
                    minRange: (-90, 90))

                // Matches postprocess.cpp's own two vertically stacked impedance subplots and its
                // 0...100Ω / ±90° minimum display ranges.
                return makeSection(title: "Net: \(netImpedance.netName)",
                                   graphs: [("Magnitude (Ω)", magnitudeChart), ("Phase (°)", angleChart)])
            }
            return sections

        case .smith:
            return preview.smithCharts.map { smith in
                let chart = SmithChartView()
                chart.setData(port: smith.port, reGamma: smith.reGamma.map(\.doubleValue),
                               imGamma: smith.imGamma.map(\.doubleValue), vswrMarginGamma: smith.vswrMarginGamma)
                return makeSection(title: "Port: \(portDisplayName(index: smith.port, preview: preview))",
                                   graphs: [("Smith Chart", chart)])
            }

        case .traceDelays:
            var sections: [NSView] = preview.diffPairs.compactMap { pair in
                var curves: [(label: String, values: [Double])] = []
                if let n = pair.nDelayNs { curves.append((label: "N", values: n.map(\.doubleValue))) }
                if let p = pair.pDelayNs { curves.append((label: "P", values: p.map(\.doubleValue))) }
                guard !curves.isEmpty else { return nil }
                let chart = MultiCurveLineChartView()
                chart.configure(yAxisLabel: "Delay (ns)", showsLabel: false)
                chart.setCurves(xValuesGHz: freqGHz, curves: curves)
                return makeSection(title: pair.name, graphs: [("Delay (ns)", chart)])
            }
            sections += preview.traces.map { trace in
                let chart = MultiCurveLineChartView()
                chart.configure(yAxisLabel: "Delay (ns)", showsLabel: false)
                chart.setCurves(xValuesGHz: freqGHz, curves: [(label: trace.name, values: trace.delayNs.map(\.doubleValue))])
                return makeSection(title: trace.name, graphs: [("Delay (ns)", chart)])
            }
            return sections

        case .probes:
            // A passive (non-absorbing) probe -- see kiems::PortConfig::absorbSignal()'s own
            // doc comment -- has no S-parameter of its own (no characteristic impedance to
            // normalize against), just raw voltage/current magnitude vs. frequency, one curve per
            // excited port that reached it.
            return preview.probes.map { probe in
                let voltageChart = MultiCurveLineChartView()
                voltageChart.configure(yAxisLabel: "Voltage (V)", showsLabel: false)
                voltageChart.setCurves(
                    xValuesGHz: freqGHz,
                    curves: probe.curves.map { (label: "exc. port \($0.excitedPort + 1)", values: $0.voltageMagnitude.map(\.doubleValue)) })

                let currentChart = MultiCurveLineChartView()
                currentChart.configure(yAxisLabel: "Current (A)", showsLabel: false)
                let currentCurves = probe.curves.map {
                    (label: "exc. port \($0.excitedPort + 1)", values: $0.currentMagnitude.map(\.doubleValue))
                }
                currentChart.setCurves(
                    xValuesGHz: freqGHz,
                    curves: currentCurves,
                    minRange: Self.nonnegativeMagnitudeRange(for: currentCurves.map { $0.values }))

                return makeSection(title: "Probe: \(probe.name)",
                                   graphs: [("Voltage (V)", voltageChart), ("Current (A)", currentChart)])
            }
        }
    }

    private func makeSection(title: String, graphs: [(title: String, view: NSView)]) -> NSView {
        // Result headings frequently embed a net name inside surrounding context ("Net: …",
        // "Excited Port: …", differential-pair labels, and eye/probe descriptions). Route the
        // complete heading through the shared net-name renderer so KiCad sub/superscript,
        // active-low overlines, and escaped slashes render consistently in every results category.
        let header = NetNameView()
        header.configure(name: title, font: .systemFont(ofSize: 13, weight: .semibold))

        let disclosureGraphs: [NSView] = graphs.map { DisclosureGraphView(title: $0.title, graph: $0.view) }
        let rows: [NSView] = [header] + disclosureGraphs
        let sectionStack = NSStackView(views: rows)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 6
        // See the outer stack's own alignment comment -- .width isn't a real fill alignment, so
        // each row's width has to be pinned explicitly instead of relying on it.
        for row in rows {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: sectionStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: sectionStack.trailingAnchor),
            ])
        }
        return sectionStack
    }

    private func portDisplayName(index: Int, preview: EMSResultsPreview) -> String {
        preview.ports.first(where: { $0.index == index })?.name ?? "Port \(index + 1)"
    }

    /// A magnitude chart with one finite/distinct value should still communicate its scale. Anchor
    /// it at zero and leave headroom above the largest measurement instead of tightly zooming into
    /// a tiny interval around that value. The 0...1 fallback is only for an entirely-zero series.
    private static func nonnegativeMagnitudeRange(for curves: [[Double]]) -> (min: Double, max: Double) {
        let peak = curves.flatMap { $0 }.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
        return (0, peak > 0 ? peak * 1.2 : 1)
    }

    /// Elementwise average and min/max band across `curves` (one array per probe, all sharing the
    /// same `count`-length frequency axis) -- ignores non-finite entries at each frequency index
    /// rather than letting one bad probe poison the whole column. A frequency index with no finite
    /// values at all reports 0 for every statistic (matches RememberRemember' own non-finite handling:
    /// nothing to plot there, not a crash).
    private static func averageAndBand(of curves: [[Double]], count: Int) -> (average: [Double], band: (low: [Double], high: [Double])) {
        var average = [Double](repeating: 0, count: count)
        var low = [Double](repeating: 0, count: count)
        var high = [Double](repeating: 0, count: count)
        for f in 0..<count {
            let values = curves.compactMap { f < $0.count && $0[f].isFinite ? $0[f] : nil }
            if values.isEmpty { continue }
            average[f] = values.reduce(0, +) / Double(values.count)
            low[f] = values.min() ?? 0
            high[f] = values.max() ?? 0
        }
        return (average, (low, high))
    }
}
