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
        addArrangedSubview(stabilityLabel)
        for view in [chart, openingLabel, stabilityLabel] {
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

    private static func height(_ volts: Double) -> String {
        let text = abs(volts) >= 1 ? String(format: "%.3g V", volts) : String(format: "%.3g mV", volts * 1e3)
        return volts > 0 ? text : "closed (\(text))"
    }

    private static func width(_ unitIntervals: Double) -> String {
        String(format: "%.2f UI", unitIntervals)
    }
}
