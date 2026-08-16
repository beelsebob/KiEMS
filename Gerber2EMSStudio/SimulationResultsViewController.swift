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
/// SimulationListViewController's outline view. Runs the real geometry -> simulate -> postprocess
/// pipeline (SimulationResultsBridge, which mirrors `geber2ems -g -s -p`) in the background the
/// first time a given simulation's Results entry is shown -- the same run/cache/error/spinner
/// pattern GeometryViewController uses, just one stage further down the pipeline (and, since it
/// includes a real FDTD run with no progress callback, potentially far slower: minutes to hours,
/// not seconds). Results (and errors) are cached per simulation index, so re-selecting an
/// already-run simulation's Results entry doesn't re-run the pipeline.
final class SimulationResultsViewController: NSViewController {
    private weak var document: Document?

    private let statusLabel = NSTextField(labelWithString: "")
    private let categoryControl = NSSegmentedControl()
    private let scrollView = NSScrollView()
    private let stack = NSStackView()

    private var previews: [Int: EMSResultsPreview] = [:]
    private var errors: [Int: String] = [:]
    private var runningIndices: Set<Int> = []
    private var currentIndex: Int?
    private var availableCategories: [ResultsCategory] = []
    private var selectedCategory: ResultsCategory = .sParameters

    /// Fired whenever a given simulation's results step starts/finishes running, so
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

            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
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

        guard previews[index] == nil, errors[index] == nil, !runningIndices.contains(index) else { return }
        runResultsStep(forSimulationIndex: index)
    }

    /// Called by DocumentWindowController whenever something that would change this simulation's
    /// results changes -- the same edits that invalidate GeometryViewController's own cache
    /// (hull-padding/via/ground-net edits, involved-nets membership/impedance/plane/width changes)
    /// -- so a stale cached result (or error) from before the edit doesn't keep being shown.
    /// Deliberately doesn't re-run immediately: just clears the cache, so the next explicit Results
    /// selection is what triggers the real re-run.
    func invalidateCache(forSimulationIndex index: Int) {
        previews[index] = nil
        errors[index] = nil
    }

    private func refreshDisplay() {
        guard let currentIndex else { return }
        if let preview = previews[currentIndex] {
            showCategories(for: preview)
        } else if let error = errors[currentIndex] {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            statusLabel.stringValue = error
            statusLabel.isHidden = false
        } else if runningIndices.contains(currentIndex) {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            statusLabel.stringValue = "Running simulation…\n\nA full FDTD run can take several minutes."
            statusLabel.isHidden = false
        } else {
            categoryControl.isHidden = true
            scrollView.isHidden = true
            statusLabel.isHidden = true
        }
    }

    private func runResultsStep(forSimulationIndex index: Int) {
        guard let document, index < document.config.simulations.count else { return }

        let simulationName = document.config.simulations[index].name
        let config = document.config
        // Always a private scratch directory, migrated into the real package only at save time --
        // see pipelineDirectory's doc comment. Doesn't require saving first either way.
        let packageDir = document.pipelineDirectory.path
        let kicadCliPath = AppPaths.resolveKicadCli()
        let helperPath = AppPaths.kicadQueryHelperPath
        let workerPath = AppPaths.fdtdWorkerPath

        runningIndices.insert(index)
        onRunStateChanged?(index, true)
        refreshDisplay()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let preview = try EMSResultsStepBridge.runResultsStep(
                    forSimulationNamed: simulationName, config: config, packageDir: packageDir,
                    kicadCliPath: kicadCliPath, kicadQueryHelperPath: helperPath, fdtdWorkerPath: workerPath)
                DispatchQueue.main.async {
                    self?.resultsStepFinished(forSimulationIndex: index, preview: preview, error: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.resultsStepFinished(forSimulationIndex: index, preview: nil, error: error)
                }
            }
        }
    }

    private func resultsStepFinished(forSimulationIndex index: Int, preview: EMSResultsPreview?, error: Error?) {
        runningIndices.remove(index)
        onRunStateChanged?(index, false)
        if let preview {
            previews[index] = preview
        } else {
            errors[index] = error?.localizedDescription ?? "Simulation failed."
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
              let currentIndex, let preview = previews[currentIndex] else { return }
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
