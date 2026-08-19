import Cocoa
import GerberCharts

/// Which group of charts is currently shown -- an NSSegmentedControl lets the user switch between
/// them; only categories with at least one section to show ever appear (see showCategories).
private enum ResultsCategory: CaseIterable {
    case sParameters
    case impedance
    case smith
    case diffPairs
    case traceDelays

    var title: String {
        switch self {
        case .sParameters: return "S-Parameters"
        case .impedance: return "Impedance"
        case .smith: return "Smith"
        case .diffPairs: return "Differential Pairs"
        case .traceDelays: return "Trace Delays"
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

    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    /// Shown left of progressBar only while EMSPipelineProgress.duringExcitation is true (the
    /// excitation pulse is still actively being injected, as opposed to the run just observing
    /// decay afterward) -- see that property's own doc comment.
    private let excitationIcon = NSImageView()
    private let timeEstimateLabel = NSTextField(labelWithString: "")
    /// Shows the energy-decay end-criteria's current value against its own dB target while the FDTD
    /// run is in progress -- see EMSPipelineProgress's own energyChangeDB/targetEnergyChangeDB doc
    /// comment. `n/10` divisions, where n is the target itself (e.g. 60dB -> 6 divisions) -- set
    /// dynamically in progressReceived() once the real target is known, not a fixed value here.
    private let energyLevelIndicator = NSLevelIndicator()
    private let categoryControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()

    // NSLevelIndicator's doubleValue, unlike NSProgressIndicator's, isn't animatable through the
    // standard `.animator()` proxy -- setting it that way just jumps instantly, no interpolation.
    // setLevelIndicatorValue(_:animated:) below drives it manually on a repeating Timer instead; this
    // is the in-flight one, invalidated/replaced every time a new target value comes in so rapid
    // progress ticks don't pile up competing animations.
    private var levelIndicatorAnimation: Timer?

    private var errors: [Int: String] = [:]
    private var runningIndices: Set<Int> = []
    // Latest known progress per simulation, from this VC's own in-flight ensureStage: call -- see
    // GeometryViewController's identical progressFraction field for why refreshDisplay() needs this
    // rather than relying solely on the live progress callback.
    private var latestProgress: [Int: EMSPipelineProgress] = [:]
    // When the *current phase* of a simulation's in-flight run began -- the basis for the elapsed-
    // time/fraction extrapolation behind timeEstimateLabel's own text (see progressReceived()). Reset
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

        statusLabel.font = .systemFont(ofSize: 20, weight: .medium) // Matches SubEntryPlaceholder's notice text.
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        // Without this, a multi-line NSTextField's intrinsicContentSize is computed before Auto
        // Layout has resolved its actual available width -- it can't know where to wrap yet, so it
        // falls back to reporting its full *unwrapped* single-line width as intrinsic. The only
        // things bounding this label's width are the <=/>= inequalities below, which don't force a
        // smaller size the way a hard width would -- so with a long enough string (a verbose error
        // message, or apparently just this text on some runs) the window itself grows to satisfy
        // that unwrapped intrinsic width. This was the real, container-independent cause behind
        // "the whole window becomes enormous" -- unrelated to any chart-rendering code.
        statusLabel.preferredMaxLayoutWidth = 400
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressBar)

        excitationIcon.image = NSImage(systemSymbolName: "waveform.path.ecg.rectangle",
                                        accessibilityDescription: "Exciting")
        excitationIcon.contentTintColor = .systemOrange
        excitationIcon.isHidden = true
        excitationIcon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(excitationIcon)

        timeEstimateLabel.font = .systemFont(ofSize: 11)
        timeEstimateLabel.textColor = .tertiaryLabelColor
        timeEstimateLabel.alignment = .center
        timeEstimateLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(timeEstimateLabel)

        energyLevelIndicator.levelIndicatorStyle = .discreteCapacity
        energyLevelIndicator.minValue = 0
        // Placeholder -- replaced with the real dB target (and number of divisions) as soon as the
        // first Simulation-phase progress report arrives (see refreshDisplay()). Counts down: shows
        // dB *remaining* until the target, not dB decayed so far -- starts full, drains to 0 as the
        // simulation approaches its end criterion.
        energyLevelIndicator.maxValue = 60
        // warningValue/criticalValue left at their own (max-exceeding) defaults, deliberately -- with
        // the countdown direction above, NSLevelIndicator's usual "getting low is bad" semantics would
        // actually point the wrong way here too (getting low means getting *close to done*), so
        // there's still no "this is bad, turn it red" threshold that makes sense to set.
        energyLevelIndicator.isEditable = false
        energyLevelIndicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(energyLevelIndicator)

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

        // See GeometryViewController's identical contentGuide for why: vertically centers the whole
        // statusLabel...energyLevelIndicator block, not just statusLabel itself, so the extra rows
        // added below it don't leave the block's visual center sitting below the container's true
        // center.
        let contentGuide = NSLayoutGuide()
        container.addLayoutGuide(contentGuide)

        NSLayoutConstraint.activate([
            categoryControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            categoryControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: categoryControl.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentGuide.topAnchor.constraint(equalTo: statusLabel.topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: energyLevelIndicator.bottomAnchor),
            contentGuide.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            progressBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 240),

            excitationIcon.trailingAnchor.constraint(equalTo: progressBar.leadingAnchor, constant: -8),
            excitationIcon.centerYAnchor.constraint(equalTo: progressBar.centerYAnchor),
            excitationIcon.widthAnchor.constraint(equalToConstant: 16),
            excitationIcon.heightAnchor.constraint(equalToConstant: 16),

            timeEstimateLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            timeEstimateLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            energyLevelIndicator.topAnchor.constraint(equalTo: timeEstimateLabel.bottomAnchor, constant: 12),
            energyLevelIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
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
        runResultsStep(forSimulationIndex: index, simulationName: name, pipeline: pipeline)
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
        document.pipeline(forSimulationNamed: document.config.simulations[index].name)
            .invalidate(from: .results)
    }

    /// Manually interpolates energyLevelIndicator's doubleValue over ~0.2s -- see
    /// levelIndicatorAnimation's own doc comment for why this can't just use `.animator()` the way
    /// progressBar does. `animated: false` snaps immediately, which also cancels any interpolation
    /// already in flight (so a phase-boundary reset can't be fought by a stale animation still
    /// chasing the previous phase's final value).
    private func setLevelIndicatorValue(_ target: Double, animated: Bool) {
        levelIndicatorAnimation?.invalidate()
        guard animated else {
            energyLevelIndicator.doubleValue = target
            return
        }
        let start = energyLevelIndicator.doubleValue
        let duration = 0.2
        let startTime = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(startTime) / duration)
            energyLevelIndicator.doubleValue = start + (target - start) * t
            if t >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelIndicatorAnimation = timer
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
            progressBar.isHidden = true
            excitationIcon.isHidden = true
            timeEstimateLabel.isHidden = true
            energyLevelIndicator.isHidden = true
            showCategories(for: preview)
        } else if let error = errors[currentIndex] {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            statusLabel.stringValue = error
            statusLabel.isHidden = false
            progressBar.isHidden = true
            excitationIcon.isHidden = true
            timeEstimateLabel.isHidden = true
            energyLevelIndicator.isHidden = true
        } else if runningIndices.contains(currentIndex) {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            let progress = latestProgress[currentIndex]
            switch progress?.phase {
            case .simulation:
                statusLabel.stringValue = "Running simulation…\n\nA full FDTD run can take several minutes."
            default:
                statusLabel.stringValue = "Building geometry…"
            }
            statusLabel.isHidden = false
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    progressBar.animator().doubleValue = progress?.fraction ?? 0
                }
            } else {
                progressBar.doubleValue = progress?.fraction ?? 0
            }
            progressBar.isHidden = false
            excitationIcon.isHidden = !(progress?.phase == .simulation && (progress?.duringExcitation ?? false))
            timeEstimateLabel.stringValue = timeEstimateText[currentIndex]
                ?? TimeRemainingFormatter.string(secondsRemaining: nil)
            timeEstimateLabel.isHidden = false
            if let progress, progress.phase == .simulation {
                energyLevelIndicator.maxValue = max(progress.targetEnergyChangeDB, 1)
                // n/10 divisions, per this level indicator's own design brief.
                energyLevelIndicator.numberOfMajorTickMarks = max(1, Int(progress.targetEnergyChangeDB / 10))
                // Counts down, not up: starts full (no decay yet) and drains toward 0 as
                // energyChangeDB approaches its target -- i.e. remaining dB still to decay, not dB
                // decayed so far.
                let remainingDB = max(0, progress.targetEnergyChangeDB - progress.energyChangeDB)
                setLevelIndicatorValue(remainingDB, animated: animated)
                energyLevelIndicator.isHidden = false
            } else {
                energyLevelIndicator.isHidden = true
            }
        } else {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            statusLabel.isHidden = true
            progressBar.isHidden = true
            excitationIcon.isHidden = true
            timeEstimateLabel.isHidden = true
            energyLevelIndicator.isHidden = true
        }
    }

    private func runResultsStep(forSimulationIndex index: Int, simulationName: String,
                                 pipeline: EMSSimulationPipelineBridge) {
        guard let document else { return }
        let config = document.config
        // Always a private scratch directory, migrated into the real package only at save time --
        // see pipelineDirectory's doc comment. Doesn't require saving first either way.
        let packageDir = document.pipelineDirectory.path
        let kicadCliPath = AppPaths.resolveKicadCli()
        let helperPath = AppPaths.kicadQueryHelperPath

        runningIndices.insert(index)
        refreshDisplay()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try pipeline.ensureStage(.results, config: config, packageDir: packageDir,
                                          kicadCliPath: kicadCliPath, kicadQueryHelperPath: helperPath,
                                          progress: { progress in
                                              DispatchQueue.main.async {
                                                  self?.progressReceived(progress, forSimulationIndex: index)
                                              }
                                          })
                DispatchQueue.main.async {
                    self?.resultsStepFinished(forSimulationIndex: index, error: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.resultsStepFinished(forSimulationIndex: index, error: error)
                }
            }
        }
    }

    /// Common handler for every EMSPipelineProgress report from this VC's own in-flight ensureStage:
    /// call -- relayed outward via onProgressChanged (for the source-list row) and, if this is the
    /// currently-shown simulation, applied to this VC's own progress bar/time estimate/level
    /// indicator too.
    private func progressReceived(_ progress: EMSPipelineProgress, forSimulationIndex index: Int) {
        latestProgress[index] = progress
        onProgressChanged?(index, progress)
        let name = simulationName(forIndex: index)
        let percent = Int((progress.fraction * 100).rounded())
        switch progress.phase {
        case .simulation:
            print("[\(name)] Simulation: \(percent)% (energy ~\(String(format: "%.2e", progress.absoluteEnergy))"
                + ", \(String(format: "%.1f", progress.energyChangeDB))"
                + "/\(String(format: "%.1f", progress.targetEnergyChangeDB)) dB)")
        default:
            print("[\(name)] Geometry: \(percent)%")
        }
        // See phaseStartTime's own doc comment for why this resets on every phase change, not just
        // once per run.
        if lastReportedPhase[index] != progress.phase {
            lastReportedPhase[index] = progress.phase
            phaseStartTime[index] = Date()
            // Snap immediately, not animated -- without this, the very next (animated) update below
            // would visibly slide from wherever the *previous* phase left off (e.g. the Geometry bar
            // sitting at 100%) down to this new phase's own starting point, transiently reading as
            // some confusing intermediate "half complete" value instead of genuinely restarting from
            // scratch the moment the new phase begins.
            if currentIndex == index {
                progressBar.doubleValue = 0
                if progress.phase == .simulation {
                    energyLevelIndicator.maxValue = max(progress.targetEnergyChangeDB, 1)
                }
                setLevelIndicatorValue(energyLevelIndicator.maxValue, animated: false)
            }
        }
        let secondsRemaining: Double?
        if let start = phaseStartTime[index], progress.fraction > 0 {
            let elapsed = Date().timeIntervalSince(start)
            secondsRemaining = max(0, elapsed / progress.fraction - elapsed)
        } else {
            secondsRemaining = nil
        }
        timeEstimateText[index] = TimeRemainingFormatter.string(secondsRemaining: secondsRemaining)
        if currentIndex == index, runningIndices.contains(index) {
            refreshDisplay(animated: true)
        }
    }

    private func simulationName(forIndex index: Int) -> String {
        guard let document, index < document.config.simulations.count else { return "simulation \(index)" }
        return document.config.simulations[index].name
    }

    private func resultsStepFinished(forSimulationIndex index: Int, error: Error?) {
        runningIndices.remove(index)
        // Read before clearing -- the last phase reported before this run stopped, so
        // onRunFinished's caller knows which stage the outcome belongs to.
        let reachedPhase = latestProgress[index]?.phase ?? .geometry
        latestProgress[index] = nil
        lastReportedPhase[index] = nil
        phaseStartTime[index] = nil
        timeEstimateText[index] = nil
        // Immediate, not animated -- see GeometryViewController.stepFinished's identical reset for
        // why: this run's own progress bar/level indicator shouldn't leave a stale value behind for
        // the next run to animate away from.
        progressBar.doubleValue = 0
        setLevelIndicatorValue(0, animated: false)
        onRunFinished?(index, reachedPhase, error == nil)
        if let error {
            errors[index] = error.localizedDescription
        } else {
            document?.updateChangeCount(.changeDone)
        }
        refreshDisplay()
    }

    // MARK: - Category/chart building

    private func showCategories(for preview: EMSResultsPreview) {
        var categories: [ResultsCategory] = []
        if !preview.sParamSets.isEmpty { categories.append(.sParameters) }
        if !preview.impedances.isEmpty { categories.append(.impedance) }
        if !preview.smithCharts.isEmpty { categories.append(.smith) }
        if !preview.diffPairs.isEmpty { categories.append(.diffPairs) }
        if !preview.traces.isEmpty { categories.append(.traceDelays) }
        availableCategories = categories

        guard !categories.isEmpty else {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            statusLabel.stringValue = "No results to display."
            statusLabel.isHidden = false
            return
        }

        categoryControl.isHidden = false
        scrollView.isHidden = false
        statusLabel.isHidden = true

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
                                    curves: set.curves.map { (label: $0.label, values: $0.magnitudeDb.map(\.doubleValue)) },
                                    minRange: (-60, 5))

                let phaseChart = MultiCurveLineChartView()
                phaseChart.configure(yAxisLabel: "Phase [°]")
                phaseChart.setCurves(xValuesGHz: freqGHz,
                                      curves: set.curves.map { (label: $0.label, values: $0.phaseDeg.map(\.doubleValue)) })

                return makeSection(title: "Excited Port: \(portDisplayName(index: set.excitedPort, preview: preview))",
                                    content: [magChart, phaseChart])
            }

        case .impedance:
            return preview.impedances.map { impedance in
                let chart = DualAxisLineChartView()
                // Matches postprocess.cpp's own renderImpedance ylim convention (0..100Ω / ±90°).
                chart.setData(xValuesGHz: freqGHz,
                               left: (label: "Magnitude [Ω]", values: impedance.magnitudeOhm.map(\.doubleValue)),
                               right: (label: "Angle [°]", values: impedance.angleDeg.map(\.doubleValue)),
                               leftMinRange: (0, 100), rightMinRange: (-90, 90))
                return makeSection(title: "Port: \(portDisplayName(index: impedance.port, preview: preview))",
                                    content: [chart])
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
        }
    }

    private func makeSection(title: String, content: [NSView]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .labelColor

        let rows = [header] + content
        let sectionStack = NSStackView(views: rows)
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
}
