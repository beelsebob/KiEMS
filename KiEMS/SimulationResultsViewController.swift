import Cocoa
import CopperUtils
import RememberRemember

/// NSScrollView positions a flipped document view from its top edge when its content is shorter
/// than the viewport. The charts retain their own native (non-flipped) drawing coordinates; only
/// this layout container needs to be flipped.
private final class ResultsDocumentStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Which group of charts is currently shown -- an NSSegmentedControl lets the user switch between
/// them; only categories with at least one section to show ever appear (see showCategories).
private enum ResultsCategory: CaseIterable {
    case sParameters
    case eyeDiagrams
    case impedance
    case smith
    case diffPairs
    case traceDelays
    case probes

    var title: String {
        switch self {
        case .sParameters: return "S-Parameters"
        case .eyeDiagrams: return "Eye diagrams"
        case .impedance: return "Impedance"
        case .smith: return "Smith"
        case .diffPairs: return "Differential Pairs"
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
    /// Shows the energy-decay end-criteria's current value against its own dB target while setup or
    /// the FDTD run is in progress -- see EMSPipelineProgress's own energyChangeDB/
    /// targetEnergyChangeDB doc comment. It starts pegged at the default target during setup, then
    /// uses the real target once the first timestep report arrives. `n/10` divisions, where n is
    /// the target itself (e.g. 60dB -> 6 divisions).
    private let energyLevelIndicator = NSLevelIndicator()
    private let energyLevelLabel = NSTextField(labelWithString: "")
    private let energyMeterStack = NSStackView()
    private static let defaultEnergyDecayTargetDB = 60.0
    private let categoryControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let stack = ResultsDocumentStackView()

    // NSLevelIndicator's doubleValue, unlike NSProgressIndicator's, isn't animatable through the
    // standard `.animator()` proxy -- setting it that way just jumps instantly, no interpolation.
    // setLevelIndicatorValue(_:animated:) below drives it manually on a repeating Timer instead; this
    // is the in-flight one, invalidated/replaced every time a new target value comes in so rapid
    // progress ticks don't pile up competing animations.
    private var levelIndicatorAnimation: Timer?
    // The time-estimate label collapses out of ProgressStatusView's stack during indeterminate
    // setup, so it cannot remain the level indicator's positional anchor in that phase.
    private var energyBelowProgressBarConstraint: NSLayoutConstraint!
    private var energyBelowTimeEstimateConstraint: NSLayoutConstraint!

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

        energyLevelIndicator.levelIndicatorStyle = .discreteCapacity
        energyLevelIndicator.minValue = 0
        // Replaced with the real dB target as soon as the first Simulation-phase progress report
        // arrives. Counts down: shows dB *remaining* until the target, not dB decayed so far.
        energyLevelIndicator.maxValue = Self.defaultEnergyDecayTargetDB
        // warningValue/criticalValue left at their own (max-exceeding) defaults, deliberately -- with
        // the countdown direction above, NSLevelIndicator's usual "getting low is bad" semantics would
        // actually point the wrong way here too (getting low means getting *close to done*), so
        // there's still no "this is bad, turn it red" threshold that makes sense to set.
        energyLevelIndicator.isEditable = false
        energyLevelIndicator.translatesAutoresizingMaskIntoConstraints = false

        energyLevelLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        energyLevelLabel.textColor = .secondaryLabelColor

        energyMeterStack.orientation = .horizontal
        energyMeterStack.alignment = .centerY
        energyMeterStack.spacing = 8
        energyMeterStack.addArrangedSubview(energyLevelIndicator)
        energyMeterStack.addArrangedSubview(energyLevelLabel)
        energyMeterStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(energyMeterStack)

        energyBelowProgressBarConstraint = energyMeterStack.topAnchor.constraint(
            equalTo: progressStatus.progressBar.bottomAnchor, constant: 12)
        energyBelowTimeEstimateConstraint = energyMeterStack.topAnchor.constraint(
            equalTo: progressStatus.timeEstimateLabel.bottomAnchor, constant: 12)
        energyBelowTimeEstimateConstraint.isActive = true

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

            excitationIcon.trailingAnchor.constraint(equalTo: progressStatus.progressBar.leadingAnchor, constant: -8),
            excitationIcon.centerYAnchor.constraint(equalTo: progressStatus.progressBar.centerYAnchor),
            excitationIcon.widthAnchor.constraint(equalToConstant: 16),
            excitationIcon.heightAnchor.constraint(equalToConstant: 16),

            energyMeterStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            energyLevelIndicator.widthAnchor.constraint(equalToConstant: 240),
            energyLevelIndicator.heightAnchor.constraint(equalToConstant: 16),
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

    /// Manually interpolates energyLevelIndicator's doubleValue over ~0.2s -- see
    /// levelIndicatorAnimation's own doc comment for why this can't just use `.animator()` the way
    /// progressStatus's own progress bar does. `animated: false` snaps immediately, which also cancels any interpolation
    /// already in flight (so a phase-boundary reset can't be fought by a stale animation still
    /// chasing the previous phase's final value).
    private func setLevelIndicatorValue(_ target: Double, animated: Bool) {
        levelIndicatorAnimation?.invalidate()
        guard animated else {
            energyLevelIndicator.doubleValue = target
            updateEnergyLevelLabel()
            return
        }
        let start = energyLevelIndicator.doubleValue
        let duration = 0.2
        let startTime = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(startTime) / duration)
            energyLevelIndicator.doubleValue = start + (target - start) * t
            updateEnergyLevelLabel()
            if t >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelIndicatorAnimation = timer
    }

    private func updateEnergyLevelLabel() {
        energyLevelLabel.stringValue = String(
            format: "%.0f/%.0f dB", energyLevelIndicator.doubleValue, energyLevelIndicator.maxValue)
    }

    private func positionEnergyLevelIndicatorForSetup(_ isSettingUp: Bool) {
        energyBelowTimeEstimateConstraint.isActive = false
        energyBelowProgressBarConstraint.isActive = false
        (isSettingUp ? energyBelowProgressBarConstraint : energyBelowTimeEstimateConstraint).isActive = true
    }

    /// `animated` smooths just the progress bar's/level indicator's own doubleValue transitions --
    /// meant for live ticks from progressReceived() (small, incremental deltas within the same
    /// simulation), not for the other call sites (selection changes, run start/finish), where the
    /// value can jump to represent an unrelated simulation's own progress and animating that jump
    /// would be misleading motion, not a smooth update.
    private func refreshDisplay(animated: Bool = false) {
        guard let currentIndex, let document, currentIndex < document.config.simulations.count else { return }
        let name = document.config.simulations[currentIndex].name
        let pipeline = document.pipeline(forSimulationNamed: name)
        if let preview = pipeline.resultsPreview() {
            // These default to visible (NSControl's own isHidden default) until a run's own
            // running/error/idle branch below first sets them -- a simulation whose results are
            // already cached before this VC's very first refreshDisplay() call (e.g. from a
            // previous session) would otherwise skip that and show them at their AppKit defaults,
            // stacked on top of the just-shown charts.
            excitationIcon.isHidden = true
            energyMeterStack.isHidden = true
            showCategories(for: preview)
        } else if let error = errors[currentIndex] {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            progressStatus.setState(.error(error))
            excitationIcon.isHidden = true
            energyMeterStack.isHidden = true
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
            positionEnergyLevelIndicatorForSetup(isSettingUp)
            if isSettingUp {
                energyLevelIndicator.maxValue = Self.defaultEnergyDecayTargetDB
                energyLevelIndicator.numberOfMajorTickMarks =
                    Int(Self.defaultEnergyDecayTargetDB / 10)
                setLevelIndicatorValue(energyLevelIndicator.maxValue, animated: false)
                energyMeterStack.isHidden = false
            } else if let progress, progress.phase == .simulation {
                energyLevelIndicator.maxValue = max(progress.targetEnergyChangeDB, 1)
                // n/10 divisions, per this level indicator's own design brief.
                energyLevelIndicator.numberOfMajorTickMarks = max(1, Int(progress.targetEnergyChangeDB / 10))
                // Counts down, not up: starts full (no decay yet) and drains toward 0 as
                // energyChangeDB approaches its target -- i.e. remaining dB still to decay, not dB
                // decayed so far.
                let remainingDB = max(0, progress.targetEnergyChangeDB - progress.energyChangeDB)
                setLevelIndicatorValue(remainingDB, animated: animated)
                energyMeterStack.isHidden = false
            } else {
                energyMeterStack.isHidden = true
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
            energyMeterStack.isHidden = true
        } else {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            progressStatus.setState(.hidden)
            excitationIcon.isHidden = true
            energyMeterStack.isHidden = true
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
                    document.updateChangeCount(.changeDone)
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
        // Immediate, not animated -- this run's own level indicator shouldn't leave a stale value
        // behind for the next run to animate away from.
        setLevelIndicatorValue(0, animated: false)
    }

    /// Common handler for every EMSPipelineProgress report from this simulation's own
    /// .geometryGeneration/.simulation jobs -- relayed outward via onProgressChanged (for the
    /// source-list row) and, if this is the currently-shown simulation, applied to this VC's own
    /// progress bar/time estimate/level indicator too.
    private func progressReceived(_ progress: EMSPipelineProgress, forSimulationIndex index: Int) {
        latestProgress[index] = progress
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

    private func simulationName(forIndex index: Int) -> String {
        guard let document, index < document.config.simulations.count else { return "simulation \(index)" }
        return document.config.simulations[index].name
    }


    // MARK: - Category/chart building

    private func showCategories(for preview: EMSResultsPreview) {
        var categories: [ResultsCategory] = []
        if !preview.sParamSets.isEmpty { categories.append(.sParameters) }
        if !preview.eyeDiagrams.isEmpty { categories.append(.eyeDiagrams) }
        if !preview.netImpedances.isEmpty { categories.append(.impedance) }
        if !preview.smithCharts.isEmpty { categories.append(.smith) }
        if !preview.diffPairs.isEmpty { categories.append(.diffPairs) }
        if !preview.traces.isEmpty { categories.append(.traceDelays) }
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
            return preview.sParamSets.map { set in
                let magChart = MultiCurveLineChartView()
                magChart.configure(yAxisLabel: "Magnitude [dB]")
                // Matches postprocess.cpp's own renderSParams ylim convention: always show at least
                // -60..5dB, expanding further only if the data genuinely needs more room. Without
                // this, a single numerically-unstable outlier point (typical near the edges of the
                // excitation's frequency band, where the incident wave's own spectrum is weak enough
                // that reflected/incident stops being a stable ratio) can dominate the auto-scaled
                // range and visually flatten the physically meaningful part of the curve.
                magChart.setCurves(xValuesGHz: freqGHz,
                                    curves: set.curves.map {
                                        (label: $0.outputPort == set.excitedPort ? "Returned to source" : $0.label,
                                         values: $0.magnitudeDb.map(\.doubleValue))
                                    },
                                    minRange: (-60, 5))

                let phaseChart = MultiCurveLineChartView()
                phaseChart.configure(yAxisLabel: "Phase [°]")
                phaseChart.setCurves(xValuesGHz: freqGHz,
                                      curves: set.curves.map {
                                          (label: $0.outputPort == set.excitedPort ? "Returned to source" : $0.label,
                                           values: $0.phaseDeg.map(\.doubleValue))
                                      })

                return makeSection(title: "Excited Port: \(portDisplayName(index: set.excitedPort, preview: preview))",
                                    content: [magChart, phaseChart])
            }

        case .eyeDiagrams:
            return preview.eyeDiagrams.map { eye in
                let chart = EyeDiagramView()
                chart.setData(timeUI: eye.timeUI.map(\.doubleValue),
                              traces: eye.traces.map { $0.map(\.doubleValue) })
                let kind = eye.isDifferential ? "Differential received signal" : "Received signal"
                let rate = String(format: "%.4g Gb/s", eye.bitRateGbps)
                return makeSection(title: "\(eye.name) — \(kind), \(rate)", content: [chart])
            }

        case .impedance:
            // Per net (a direct characteristic-impedance measurement from one or more non-loading
            // trace probes -- see EMSResultsNetImpedance's own doc comment), not per absorbing port
            // -- an average line, a shaded min/max band across that net's own probes, and each
            // probe's own curve drawn thin underneath.
            return preview.netImpedances.map { netImpedance in
                let probeMagnitudes = netImpedance.probes.map { $0.magnitudeOhm.map(\.doubleValue) }
                let probeAngles = netImpedance.probes.map { $0.angleDeg.map(\.doubleValue) }
                let probeLabels = netImpedance.probes.indices.map { "Probe \($0 + 1)" }

                let magnitudeChart = MultiCurveLineChartView()
                magnitudeChart.configure(yAxisLabel: "Magnitude [Ω]")
                let magStats = Self.averageAndBand(of: probeMagnitudes, count: freqGHz.count)
                magnitudeChart.setBandedCurves(
                    xValuesGHz: freqGHz,
                    probeCurves: zip(probeLabels, probeMagnitudes).map { ($0, $1) },
                    averageLabel: "Average |Z|", average: magStats.average, band: magStats.band,
                    minRange: (0, 100), xAxisLabel: nil)

                let angleChart = MultiCurveLineChartView()
                angleChart.configure(yAxisLabel: "Angle [°]")
                let angleStats = Self.averageAndBand(of: probeAngles, count: freqGHz.count)
                angleChart.setBandedCurves(
                    xValuesGHz: freqGHz,
                    probeCurves: zip(probeLabels, probeAngles).map { ($0, $1) },
                    averageLabel: "Average arg(Z)", average: angleStats.average, band: angleStats.band,
                    minRange: (-90, 90))

                // Matches postprocess.cpp's own two vertically stacked impedance subplots and its
                // 0...100Ω / ±90° minimum display ranges.
                return makeSection(title: "Net: \(netImpedance.netName)", content: [magnitudeChart, angleChart])
            }

        case .smith:
            return preview.smithCharts.map { smith in
                let chart = SmithChartView()
                chart.setData(port: smith.port, reGamma: smith.reGamma.map(\.doubleValue),
                               imGamma: smith.imGamma.map(\.doubleValue), vswrMarginGamma: smith.vswrMarginGamma)
                return makeSection(title: "Port: \(portDisplayName(index: smith.port, preview: preview))", content: [chart])
            }

        case .diffPairs:
            return preview.diffPairs.map { pair in
                var content: [NSView] = []
                if pair.sdd11Db != nil || pair.sdd21Db != nil {
                    var curves: [(label: String, values: [Double])] = []
                    if let sdd11 = pair.sdd11Db { curves.append((label: "SDD11", values: sdd11.map(\.doubleValue))) }
                    if let sdd21 = pair.sdd21Db { curves.append((label: "SDD21", values: sdd21.map(\.doubleValue))) }
                    let chart = MultiCurveLineChartView()
                    chart.configure(yAxisLabel: "Magnitude [dB]")
                    // Matches postprocess.cpp's own renderDiffPairSParams ylim convention.
                    chart.setCurves(xValuesGHz: freqGHz, curves: curves, minRange: (-60, 5))
                    content.append(chart)
                }
                if let mag = pair.impedanceMagnitudeOhm, let angle = pair.impedanceAngleDeg {
                    let chart = DualAxisLineChartView()
                    // Matches postprocess.cpp's own renderDiffImpedance ylim convention (0..200Ω, a
                    // wider default window than single-ended impedance's 0..100Ω) / ±90°.
                    chart.setData(xValuesGHz: freqGHz,
                                   left: (label: "|Z diff| [Ω]", values: mag.map(\.doubleValue)),
                                   right: (label: "Angle [°]", values: angle.map(\.doubleValue)),
                                   leftMinRange: (0, 200), rightMinRange: (-90, 90))
                    content.append(chart)
                }
                if pair.nDelayNs != nil || pair.pDelayNs != nil {
                    var curves: [(label: String, values: [Double])] = []
                    if let n = pair.nDelayNs { curves.append((label: "N", values: n.map(\.doubleValue))) }
                    if let p = pair.pDelayNs { curves.append((label: "P", values: p.map(\.doubleValue))) }
                    let chart = MultiCurveLineChartView()
                    chart.configure(yAxisLabel: "Delay [ns]")
                    chart.setCurves(xValuesGHz: freqGHz, curves: curves)
                    content.append(chart)
                }
                return makeSection(title: pair.name, content: content)
            }

        case .traceDelays:
            return preview.traces.map { trace in
                let chart = MultiCurveLineChartView()
                chart.configure(yAxisLabel: "Delay [ns]")
                chart.setCurves(xValuesGHz: freqGHz, curves: [(label: trace.name, values: trace.delayNs.map(\.doubleValue))])
                return makeSection(title: trace.name, content: [chart])
            }

        case .probes:
            // A passive (non-absorbing) probe -- see kicad_ems::PortConfig::absorbSignal()'s own
            // doc comment -- has no S-parameter of its own (no characteristic impedance to
            // normalize against), just raw voltage/current magnitude vs. frequency, one curve per
            // excited port that reached it.
            return preview.probes.map { probe in
                let voltageChart = MultiCurveLineChartView()
                voltageChart.configure(yAxisLabel: "|V| [V]")
                voltageChart.setCurves(
                    xValuesGHz: freqGHz,
                    curves: probe.curves.map { (label: "exc. port \($0.excitedPort + 1)", values: $0.voltageMagnitude.map(\.doubleValue)) })

                let currentChart = MultiCurveLineChartView()
                currentChart.configure(yAxisLabel: "|I| [A]")
                currentChart.setCurves(
                    xValuesGHz: freqGHz,
                    curves: probe.curves.map { (label: "exc. port \($0.excitedPort + 1)", values: $0.currentMagnitude.map(\.doubleValue)) })

                return makeSection(title: "Probe: \(probe.name)", content: [voltageChart, currentChart])
            }
        }
    }

    private func makeSection(title: String, content: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .labelColor

        let rows = [header] + content
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
