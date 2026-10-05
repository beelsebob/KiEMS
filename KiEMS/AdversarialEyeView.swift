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
    private let openingLabel = NSTextField(wrappingLabelWithString: "")
    private let stabilityLabel = NSTextField(wrappingLabelWithString: "")
    private let statisticsGrid = NSGridView(numberOfColumns: 2, rows: 0)
    private let onModeChanged: (Bool) -> Void

    /// `showsAdversarial` picks the initial mode; `onModeChanged` reports the user's later choices
    /// so the owner can carry them over to the next eyes it builds.
    init(eye: EMSResultsEyeDiagram, showsAdversarial: Bool, onModeChanged: @escaping (Bool) -> Void) {
        self.eye = eye
        self.onModeChanged = onModeChanged
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        spacing = 6

        for label in [openingLabel, stabilityLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.isSelectable = true
        }
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
            addArrangedSubview(modeControl)
        }
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
        for view in [chart, openingLabel, statisticsRow, stabilityLabel] {
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
            chart.setData(timeUI: timeUI, traces: eye.traces.map { $0.map(\.doubleValue) })
            openingLabel.stringValue = "Opening: \(Self.height(eye.heightV)) high, " +
                "\(Self.width(eye.widthUI)) wide."
            showStatistics(eye.statistics, heightV: eye.heightV, widthUI: eye.widthUI)
            stabilityLabel.isHidden = true
            return
        }
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
            stabilityLabel.textColor = .systemGreen
        } else {
            stabilityLabel.stringValue = "Not yet stable: the replicates differ by more than \(percent)% of " +
                "the opening. Increase Adversarial Draws in the simulation's properties."
            stabilityLabel.textColor = .systemOrange
        }
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
