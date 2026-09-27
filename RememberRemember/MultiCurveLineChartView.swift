import AppKit

/// A single-Y-axis LineChartView with an external axis-unit caption above it -- LineChartView
/// itself only draws tick numbers, not an axis title, so this adds the "Magnitude [dB]"-style
/// label as a plain text field instead of rotated in-canvas text. Used for any results plot that's
/// a plain multi-curve line chart: S-parameter magnitude/phase, differential SDD, trace/
/// differential-pair delay. See DualAxisLineChartView for the two-Y-axis variant.
public final class MultiCurveLineChartView: NSView {
    private let yAxisLabel = NSTextField(labelWithString: "")
    private let chart = LineChartView()
    private var configuredYAxisLabel = ""

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        yAxisLabel.font = .systemFont(ofSize: 11, weight: .medium)
        yAxisLabel.textColor = .secondaryLabelColor
        yAxisLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(yAxisLabel)

        chart.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chart)

        NSLayoutConstraint.activate([
            yAxisLabel.topAnchor.constraint(equalTo: topAnchor),
            yAxisLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            yAxisLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            chart.topAnchor.constraint(equalTo: yAxisLabel.bottomAnchor, constant: 4),
            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor),
            chart.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Supplies the Y quantity name/unit used both by the optional caption and the chart's hover
    /// readout. A disclosure graph already shows this caption in its own heading, so those callers
    /// can hide this duplicate while retaining the metadata needed by the readout.
    public func configure(yAxisLabel label: String, showsLabel: Bool = true) {
        configuredYAxisLabel = label
        // Keep a hidden duplicate caption from reserving its non-empty intrinsic height. The full
        // label remains in configuredYAxisLabel for hover metadata even when another view presents
        // the same heading.
        yAxisLabel.stringValue = showsLabel ? label : ""
        yAxisLabel.isHidden = !showsLabel || label.isEmpty
    }

    /// Replaces the chart's data. Every curve shares `xValuesGHz` as its X series. `minRange` --
    /// see LineChartView.setData's own doc comment -- keeps the axis showing at least this window
    /// regardless of the data's own extent.
    public func setCurves(xValuesGHz: [Double], curves: [(label: String, values: [Double])],
                           minRange: (min: Double, max: Double)? = nil,
                           xAxisScale: ChartXAxisScale = .logarithmic,
                           xAxisLabel: String? = "Frequency [GHz]") {
        setStyledCurves(
            xValuesGHz: xValuesGHz,
            curves: curves.map { ChartCurve(label: $0.label, values: $0.values) },
            minRange: minRange,
            xAxisScale: xAxisScale,
            xAxisLabel: xAxisLabel)
    }

    /// The styled counterpart to setCurves(_:), for plots where individual series need their own
    /// stroke widths or dash styles. Keeping this separate leaves the concise tuple-based API used
    /// by the ordinary results charts unchanged.
    public func setStyledCurves(xValuesGHz: [Double], curves: [ChartCurve],
                                minRange: (min: Double, max: Double)? = nil,
                                xAxisMinRange: (min: Double, max: Double)? = nil,
                                xIntensityBand: ChartXIntensityBand? = nil,
                                xAxisScale: ChartXAxisScale = .logarithmic,
                                xAxisLabel: String? = "Frequency [GHz]") {
        chart.setData(xValues: xValuesGHz, curves: curves,
                      leftAxisMinRange: minRange, xAxisMinRange: xAxisMinRange,
                      xIntensityBand: xIntensityBand, xAxisScale: xAxisScale, xAxisLabel: xAxisLabel,
                      leftYAxisLabel: configuredYAxisLabel)
    }

    /// A single average curve at the normal stroke weight, a shaded min/max band behind it, and
    /// every individual measurement it was averaged from drawn as its own thin curve on top -- e.g.
    /// several trace-impedance probes' own magnitude/angle vs. an averaged net-level value. Additive
    /// alongside setCurves(_:) above (which stays untouched for every other, unbanded chart).
    public func setBandedCurves(xValuesGHz: [Double], probeCurves: [(label: String, values: [Double])],
                                 averageLabel: String, average: [Double], band: (low: [Double], high: [Double]),
                                 minRange: (min: Double, max: Double)? = nil,
                                 xAxisScale: ChartXAxisScale = .logarithmic,
                                 xAxisLabel: String? = "Frequency [GHz]") {
        var curves = [ChartCurve(label: averageLabel, values: average)]
        curves += probeCurves.map { ChartCurve(label: $0.label, values: $0.values, lineWidth: 0.75) }
        chart.setData(xValues: xValuesGHz, curves: curves, band: ChartBand(low: band.low, high: band.high),
                       leftAxisMinRange: minRange, xAxisScale: xAxisScale, xAxisLabel: xAxisLabel,
                       leftYAxisLabel: configuredYAxisLabel)
    }
}
