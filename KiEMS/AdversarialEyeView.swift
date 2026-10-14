import Cocoa
import RememberRemember

/// One eye diagram plus its opening, and -- when adversarial excitations reach it -- a switch
/// between the noise-free eye and the eye with their noise added, along with how settled that
/// noisy result is (see EMSResultsEyeNoise).
final class AdversarialEyeView: NSStackView {
    /// Replicates must agree to within this fraction of the noise-free opening for the noisy eye
    /// to count as stable.
    private static let stableSpreadFraction = 0.05

    private let eye: EMSResultsEyeDiagram
    private let modeControl = NSSegmentedControl(labels: ["Noise-Free", "With Adversarial Signals"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let chart = EyeDiagramView()
    /// The mask test's verdict, above the chart: a red stop sign and what left the valid area, or
    /// a green pass. Hidden when the simulation has no mask.
    private let maskIcon = NSImageView()
    private let maskLabel = NSTextField(wrappingLabelWithString: "")
    private let maskRow = NSStackView()
    private let openingLabel = NSTextField(wrappingLabelWithString: "")
    private let stabilityLabel = NSTextField(wrappingLabelWithString: "")
    private let statisticsGrid = NSGridView(numberOfColumns: 2, rows: 0)
    private let onModeChanged: (Bool) -> Void
    /// Green for a pass: ResultsReport's darker one when printing.
    private let passColor: NSColor
    /// Red for a failure, likewise.
    private let failColor: NSColor

    /// `showsAdversarial` picks the initial mode; `onModeChanged` reports the user's later choices
    /// so the owner can carry them over to the next eyes it builds.
    /// `showsModeControl` false leaves out the mode switch and `chartHeight` replaces the chart's
    /// own height, for a fixed rendering such as the PDF report's, and `usesPrintColors` colours the
    /// traces for paper.
    init(eye: EMSResultsEyeDiagram, showsAdversarial: Bool, showsModeControl: Bool = true,
         chartHeight: CGFloat? = nil, usesPrintColors: Bool = false, onModeChanged: @escaping (Bool) -> Void) {
        self.eye = eye
        self.onModeChanged = onModeChanged
        passColor = usesPrintColors ? ResultsReport.passGreen : .systemGreen
        failColor = usesPrintColors ? ResultsReport.failRed : .systemRed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        spacing = 6

        for label in [openingLabel, stabilityLabel, maskLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.isSelectable = true
            // Nonzero from the start -- zero means automatic wrapping; see layout().
            label.preferredMaxLayoutWidth = 400
        }
        maskLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        maskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        maskIcon.setContentHuggingPriority(.required, for: .horizontal)
        maskRow.orientation = .horizontal
        maskRow.alignment = .top
        maskRow.spacing = 4
        maskRow.addArrangedSubview(maskIcon)
        maskRow.addArrangedSubview(maskLabel)
        openingLabel.textColor = .secondaryLabelColor
        statisticsGrid.translatesAutoresizingMaskIntoConstraints = false
        statisticsGrid.rowSpacing = 2
        statisticsGrid.columnSpacing = 12
        statisticsGrid.column(at: 1).xPlacement = .trailing

        if eye.noise != nil {
            modeControl.controlSize = .small
            modeControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            modeControl.target = self
            modeControl.action = #selector(modeChanged)
            modeControl.selectedSegment = showsAdversarial ? 1 : 0
            if showsModeControl {
                addArrangedSubview(modeControl)
            }
        }
        chart.usesPrintColors = usesPrintColors
        if let chartHeight {
            chart.constraints.first { $0.firstAttribute == .height && $0.secondItem == nil }?.constant = chartHeight
        }
        addArrangedSubview(maskRow)
        addArrangedSubview(chart)
        addArrangedSubview(openingLabel)
        // The table sits at its natural width, centred in a full-width row, so each name stays
        // next to its value.
        let statisticsRow = NSView()
        statisticsRow.translatesAutoresizingMaskIntoConstraints = false
        statisticsRow.addSubview(statisticsGrid)
        NSLayoutConstraint.activate([
            statisticsGrid.topAnchor.constraint(equalTo: statisticsRow.topAnchor),
            statisticsGrid.bottomAnchor.constraint(equalTo: statisticsRow.bottomAnchor),
            statisticsGrid.centerXAnchor.constraint(equalTo: statisticsRow.centerXAnchor),
            statisticsGrid.leadingAnchor.constraint(greaterThanOrEqualTo: statisticsRow.leadingAnchor),
        ])
        addArrangedSubview(statisticsRow)
        addArrangedSubview(stabilityLabel)
        for view in [maskRow, chart, openingLabel, statisticsRow, stabilityLabel] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        update()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The wrapping labels get an explicit wrap width rather than wrapping automatically to
    /// whatever width Auto Layout gives them: automatic wrapping makes every label's height (and
    /// so every following eye's position) a function of the results stack's width, which makes the
    /// layout engine's rows dense -- switching away from a page of eyes took minutes. See
    /// SmithChartView's heightConstraint for the same problem.
    override func layout() {
        super.layout()
        for label in [openingLabel, stabilityLabel] where label.preferredMaxLayoutWidth != bounds.width {
            label.preferredMaxLayoutWidth = bounds.width
        }
        let maskWidth = max(bounds.width - maskIcon.fittingSize.width - maskRow.spacing, 1)
        if maskLabel.preferredMaxLayoutWidth != maskWidth {
            maskLabel.preferredMaxLayoutWidth = maskWidth
        }
    }

    /// The convergence of the noisy eye's height with draws, for a separate disclosure graph; nil
    /// without adversarial noise.
    func makeConvergenceChart() -> NSView? {
        guard let noise = eye.noise, noise.convergenceDraws.count > 1 else { return nil }
        let chart = MultiCurveLineChartView()
        chart.configure(yAxisLabel: "Eye height (mV)", showsLabel: false)
        let millivolts = { (values: [NSNumber]) in values.map { $0.doubleValue * 1e3 } }
        chart.setBandedCurves(
            xValuesGHz: noise.convergenceDraws.map(\.doubleValue),
            probeCurves: [],
            averageLabel: "Eye height, all replicates",
            average: millivolts(noise.convergenceHeightV),
            band: (low: millivolts(noise.convergenceHeightLowestV),
                   high: millivolts(noise.convergenceHeightHighestV)),
            xAxisScale: .logarithmic,
            xAxisLabel: "Draws")
        return chart
    }

    @objc private func modeChanged() {
        onModeChanged(modeControl.selectedSegment == 1)
        update()
    }

    private func update() {
        let timeUI = eye.timeUI.map(\.doubleValue)
        guard let noise = eye.noise, modeControl.selectedSegment == 1 else {
            showMaskResult(eye.maskResult, otherFailure: eye.noise?.maskResult.flatMap { $0.passed ? nil : "with adversarial signals" })
            chart.setData(timeUI: timeUI, traces: eye.traces.map { $0.map(\.doubleValue) })
            openingLabel.stringValue = "Opening: \(Self.height(eye.heightV)) high, " +
                "\(Self.width(eye.widthUI)) wide."
            showStatistics(eye.statistics, heightV: eye.heightV, widthUI: eye.widthUI)
            stabilityLabel.isHidden = true
            return
        }
        showMaskResult(noise.maskResult, otherFailure: eye.maskResult.flatMap { $0.passed ? nil : "noise-free" })
        chart.setData(timeUI: timeUI, traces: noise.traces.map { $0.map(\.doubleValue) })
        let signals = noise.aggressorCount == 1 ? "1 adversarial signal" : "\(noise.aggressorCount) adversarial signals"
        openingLabel.stringValue =
            "Opening: \(Self.height(noise.heightV)) high " +
            "(replicates \(Self.height(noise.lowestHeightV)) – \(Self.height(noise.highestHeightV))), " +
            "\(Self.width(noise.widthUI)) wide " +
            "(\(Self.width(noise.lowestWidthUI)) – \(Self.width(noise.highestWidthUI))). " +
            "\(noise.drawCount) draws of \(signals) across \(noise.replicateCount) independent replicates."
        showStatistics(noise.statistics, heightV: noise.heightV, widthUI: noise.widthUI)

        // Judged against the noise-free opening rather than the noisy one, which can legitimately
        // be near zero (a closed eye) while still being well determined.
        let heightReference = max(eye.heightV, abs(noise.heightV), .ulpOfOne)
        let widthReference = max(eye.widthUI, noise.widthUI, .ulpOfOne)
        let stable = noise.highestHeightV - noise.lowestHeightV <= Self.stableSpreadFraction * heightReference &&
            noise.highestWidthUI - noise.lowestWidthUI <= Self.stableSpreadFraction * widthReference
        let percent = Int((Self.stableSpreadFraction * 100).rounded())
        stabilityLabel.isHidden = false
        if stable {
            stabilityLabel.stringValue = "Stable: the replicates agree to within \(percent)% of the opening."
            stabilityLabel.textColor = passColor
        } else {
            stabilityLabel.stringValue = "Not yet stable: the replicates differ by more than \(percent)% of " +
                "the opening. Increase Adversarial Draws in the simulation's properties."
            stabilityLabel.textColor = .systemOrange
        }
    }

    /// Shows how the eye being displayed fared against the mask -- `result` -- and overlays the mask
    /// on the chart. `otherFailure` names the other mode (noise-free or with adversarial signals)
    /// when that one fails, so a passing view doesn't hide a failing one.
    private func showMaskResult(_ result: EMSResultsEyeMaskResult?, otherFailure: String?) {
        guard let mask = eye.mask, let result else {
            maskRow.isHidden = true
            chart.setMask(nil)
            return
        }
        let threshold = eye.thresholdV
        var keepOut: [CGPoint] = []
        if mask.y1 > 0 && mask.x1 < 0.5 {
            // Clamped the way kiems::EyeMask's tester clamps it.
            let x1 = max(mask.x1, 0)
            let x2 = min(max(mask.x2, x1), 0.5)
            keepOut = [(x1, 0.0), (x2, -mask.y1), (1 - x2, -mask.y1), (1 - x1, 0.0), (1 - x2, mask.y1), (x2, mask.y1)]
                .map { CGPoint(x: $0.0, y: threshold + $0.1) }
        }
        let limits = mask.y2 > 0 ? (threshold - mask.y2)...(threshold + mask.y2) : nil
        chart.setMask(EyeDiagramMask(keepOut: keepOut, limits: limits, violated: !result.passed))

        let name = mask.standard == .custom ? "the eye mask" : "the \(EyeTestPreset.title(for: mask.standard)) eye mask"
        maskRow.isHidden = false
        if result.passed {
            if let otherFailure {
                maskLabel.stringValue = "Passes \(name) here, but fails it \(otherFailure)."
                showMaskIcon(failed: true)
            } else {
                maskLabel.stringValue = "Passes \(name)."
                showMaskIcon(failed: false)
            }
            return
        }
        let traces = result.traceCount.formatted()
        var failures: [String] = []
        if result.keepOutViolations > 0 {
            failures.append("\(result.keepOutViolations.formatted()) of \(traces) bits enter the keep-out region")
        }
        if result.outerLimitViolations > 0 {
            failures.append("\(result.outerLimitViolations.formatted()) of \(traces) go beyond ±\(Self.volts(mask.y2))")
        }
        maskLabel.stringValue = "Signal leaves the valid area of \(name): \(failures.joined(separator: "; "))."
        showMaskIcon(failed: true)
    }

    private func showMaskIcon(failed: Bool) {
        let symbol = failed ? "exclamationmark.octagon.fill" : "checkmark.circle.fill"
        maskIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: failed ? "Failed" : "Passed")
        maskIcon.contentTintColor = failed ? failColor : passColor
        maskLabel.textColor = failed ? failColor : passColor
    }

    /// The figures a receiver specification is usually written against, as a two-column table.
    private func showStatistics(_ statistics: EMSResultsEyeStatistics, heightV: Double, widthUI: Double) {
        while statisticsGrid.numberOfRows > 0 {
            statisticsGrid.removeRow(at: 0)
        }
        let picoseconds = { (unitIntervals: Double) in
            self.eye.bitRateGbps > 0 ? String(format: " (%.3g ps)", unitIntervals * 1e3 / self.eye.bitRateGbps) : ""
        }
        var rows: [(String, String)] = [
            ("Eye height", Self.height(heightV)),
            ("Eye width", Self.width(widthUI) + picoseconds(widthUI)),
            ("Sampling point", String(format: "%.2f UI", statistics.samplingUI)),
            ("Mean levels", "1: \(Self.volts(statistics.oneLevelV)), 0: \(Self.volts(statistics.zeroLevelV))"),
            ("Eye amplitude", Self.volts(statistics.amplitudeV)),
        ]
        if statistics.amplitudeV > 0 {
            rows.append(("Height / amplitude", String(format: "%.0f%%", max(0, heightV) / statistics.amplitudeV * 100)))
        }
        rows.append(("Jitter (peak-to-peak)", Self.width(statistics.jitterUI) + picoseconds(statistics.jitterUI)))
        if statistics.qFactor > 0 {
            // Gaussian estimate; only meaningful as a comparison when the spread is mostly random.
            let ber = 0.5 * erfc(statistics.qFactor / 2.0.squareRoot())
            let berText = ber < 1e-30 ? "< 1e-30" : String(format: "≈ %.1e", ber)
            rows.append(("Q-factor", String(format: "%.2f (Gaussian BER %@)", statistics.qFactor, berText)))
        } else {
            rows.append(("Q-factor", "– (no spread in the sampled levels)"))
        }
        for (name, value) in rows {
            let nameLabel = NSTextField(labelWithString: name)
            let valueLabel = NSTextField(labelWithString: value)
            for label in [nameLabel, valueLabel] {
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                label.isSelectable = true
            }
            nameLabel.textColor = .secondaryLabelColor
            nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            valueLabel.alignment = .right
            statisticsGrid.addRow(with: [nameLabel, valueLabel])
        }
    }

    private static func volts(_ volts: Double) -> String {
        abs(volts) >= 1 ? String(format: "%.3g V", volts) : String(format: "%.3g mV", volts * 1e3)
    }

    private static func height(_ volts: Double) -> String {
        let text = abs(volts) >= 1 ? String(format: "%.3g V", volts) : String(format: "%.3g mV", volts * 1e3)
        return volts > 0 ? text : "closed (\(text))"
    }

    private static func width(_ unitIntervals: Double) -> String {
        String(format: "%.2f UI", unitIntervals)
    }
}
