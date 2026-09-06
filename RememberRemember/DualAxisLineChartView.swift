import AppKit

/// A two-Y-axis LineChartView (magnitude on the left, phase/angle on the right, dashed) -- used for
/// per-port and per-differential-pair impedance, where magnitude and phase share one chart instead
/// of the two stacked subplots the CLI's own PNG renders. See MultiCurveLineChartView for the
/// single-axis, many-curve variant.
public final class DualAxisLineChartView: NSView {
    private let chart = LineChartView()

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        chart.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chart)
        NSLayoutConstraint.activate([
            chart.topAnchor.constraint(equalTo: topAnchor),
            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor),
            chart.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `left`/`right` share `xValuesGHz`; `left` renders on the left (magnitude) axis as a solid
    /// line, `right` on the right (phase/angle) axis as a dashed line -- matching the CLI's own
    /// solid-magnitude/dashed-phase convention (renderImpedance/renderDiffImpedance). `leftMinRange`/
    /// `rightMinRange` -- see LineChartView.setData's own doc comment -- keep each axis showing at
    /// least that window regardless of the data's own extent.
    public func setData(xValuesGHz: [Double], left: (label: String, values: [Double]), right: (label: String, values: [Double]),
                         leftMinRange: (min: Double, max: Double)? = nil, rightMinRange: (min: Double, max: Double)? = nil,
                         xAxisLabel: String? = "Frequency [GHz]") {
        chart.setData(xValues: xValuesGHz, curves: [
            ChartCurve(label: left.label, values: left.values, axis: .left),
            ChartCurve(label: right.label, values: right.values, axis: .right, dashed: true),
        ], leftAxisMinRange: leftMinRange, rightAxisMinRange: rightMinRange, xAxisLabel: xAxisLabel)
    }
}
