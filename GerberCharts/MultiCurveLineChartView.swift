import AppKit

/// A single-Y-axis LineChartView with an external axis-unit caption above it -- LineChartView
/// itself only draws tick numbers, not an axis title, so this adds the "Magnitude [dB]"-style
/// label as a plain text field instead of rotated in-canvas text. Used for any results plot that's
/// a plain multi-curve line chart: S-parameter magnitude/phase, differential SDD, trace/
/// differential-pair delay. See DualAxisLineChartView for the two-Y-axis variant.
public final class MultiCurveLineChartView: NSView {
    private let yAxisLabel = NSTextField(labelWithString: "")
    private let chart = LineChartView()

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

    public func configure(yAxisLabel label: String) {
        yAxisLabel.stringValue = label
    }

    /// Replaces the chart's data. Every curve shares `xValuesGHz` as its X series. `minRange` --
    /// see LineChartView.setData's own doc comment -- keeps the axis showing at least this window
    /// regardless of the data's own extent.
    public func setCurves(xValuesGHz: [Double], curves: [(label: String, values: [Double])],
                           minRange: (min: Double, max: Double)? = nil, xAxisLabel: String? = "Frequency [GHz]") {
        chart.setData(xValues: xValuesGHz, curves: curves.map { ChartCurve(label: $0.label, values: $0.values) },
                       leftAxisMinRange: minRange, xAxisLabel: xAxisLabel)
    }
}
