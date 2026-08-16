import AppKit

/// Which Y axis a curve is plotted against -- `.right` only has any effect if at least one curve
/// in the same LineChartView uses it, at which point a second axis (with its own independently
/// nice-numbered range) is drawn.
public enum ChartAxisSide {
    case left
    case right
}

/// One curve on a LineChartView: a label (shown in the legend), Y values sharing the chart's own X
/// values (by index -- `values[i]` corresponds to the i-th X value passed to `setData`), which axis
/// it's plotted against, and whether it's drawn dashed (used for a secondary/phase-like quantity
/// sharing a chart with a primary magnitude-like one).
public struct ChartCurve {
    public var label: String
    public var values: [Double]
    public var axis: ChartAxisSide
    public var dashed: Bool

    public init(label: String, values: [Double], axis: ChartAxisSide = .left, dashed: Bool = false) {
        self.label = label
        self.values = values
        self.axis = axis
        self.dashed = dashed
    }
}

/// A basic, self-contained X/Y line chart: gridlines, tick labels, a legend, one or more
/// color-coded curves, and an optional secondary (right) Y axis -- pure Core Graphics, no external
/// dependency. Built specifically to replace DGCharts (a third-party charting library), which was
/// confirmed, through careful bisection, to corrupt this app's window layout under real use; this
/// is deliberately minimal -- no pan/zoom, no animation, no chart types beyond a line plot -- since
/// that's all Gerber2EMSStudio's results view actually needs, and every added feature is more
/// surface area for the same class of bug to hide in again.
public final class LineChartView: NSView {
    private var xValues: [Double] = []
    private var curves: [ChartCurve] = []
    private var leftAxisMinRange: (min: Double, max: Double)?
    private var rightAxisMinRange: (min: Double, max: Double)?
    private var xAxisLabel: String?

    private static let tickFont = NSFont.systemFont(ofSize: 9)
    private static let legendFont = NSFont.systemFont(ofSize: 10)
    private static let gridColor = NSColor.gray.withAlphaComponent(0.25)
    private static let axisColor = NSColor.gray.withAlphaComponent(0.6)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 220).isActive = true
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the chart's data. Every curve's `values[i]` corresponds to `xValues[i]` -- shorter
    /// curves are drawn only as far as they have data. `leftAxisMinRange`/`rightAxisMinRange`
    /// mirror postprocess.cpp's own `ylim({min(cur, X), max(cur, Y)})` convention (see e.g.
    /// renderSParams) -- the axis always shows *at least* this window regardless of the data's own
    /// extent, expanding further only if the data genuinely needs more room. Matches the CLI's own
    /// PNG output exactly, and keeps an unusual/artifact-y outlier point (e.g. a spurious spike near
    /// the edge of the excitation bandwidth, where the incident wave's spectrum is weak enough that
    /// reflected/incident becomes numerically unstable) from making the axis auto-scale to a range
    /// so wide the physically meaningful part of the curve gets visually flattened.
    public func setData(xValues: [Double], curves: [ChartCurve], leftAxisMinRange: (min: Double, max: Double)? = nil,
                         rightAxisMinRange: (min: Double, max: Double)? = nil, xAxisLabel: String? = nil) {
        self.xValues = xValues
        self.curves = curves
        self.leftAxisMinRange = leftAxisMinRange
        self.rightAxisMinRange = rightAxisMinRange
        self.xAxisLabel = xAxisLabel
        needsDisplay = true
    }

    public override var isFlipped: Bool { false }

    private static let legendRowHeight: CGFloat = 14

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, !xValues.isEmpty else { return }

        let hasRightAxis = curves.contains { $0.axis == .right }
        let leftCurves = curves.filter { $0.axis == .left }
        let rightCurves = curves.filter { $0.axis == .right }

        let tickAttrs: [NSAttributedString.Key: Any] = [.font: Self.tickFont, .foregroundColor: NSColor.secondaryLabelColor]
        let legendAttrs: [NSAttributedString.Key: Any] = [.font: Self.legendFont, .foregroundColor: NSColor.labelColor]

        let leftMargin: CGFloat = 42
        let rightMargin: CGFloat = hasRightAxis ? 42 : 10
        // Curve labels can be long ("Response at U8 pin 4") -- the legend wraps to as many rows as
        // it needs (see legendRows()), so the reserved top margin has to match however many rows
        // that turned out to be, with a bit of extra breathing room below the last row so its text
        // doesn't run into the plot border.
        let legendRows = legendRows(attrs: legendAttrs, availableWidth: bounds.width - 8)
        let topMargin: CGFloat = legendRows.isEmpty ? 8 : 6 + CGFloat(legendRows.count) * Self.legendRowHeight + 6
        let bottomMargin: CGFloat = xAxisLabel == nil ? 16 : 28

        let plotRect = CGRect(x: bounds.minX + leftMargin, y: bounds.minY + bottomMargin,
                               width: bounds.width - leftMargin - rightMargin,
                               height: bounds.height - topMargin - bottomMargin)
        guard plotRect.width > 1, plotRect.height > 1 else { return }

        let xRange = NiceAxisRange.range(min: xValues.min() ?? 0, max: xValues.max() ?? 1, targetTicks: 6)
        let leftValues = leftCurves.flatMap(\.values).filter(\.isFinite)
        let leftDataMin = min(leftValues.min() ?? 0, leftAxisMinRange?.min ?? .infinity)
        let leftDataMax = max(leftValues.max() ?? 1, leftAxisMinRange?.max ?? -.infinity)
        let leftRange = NiceAxisRange.range(min: leftDataMin, max: leftDataMax, targetTicks: 5)
        let rightValues = rightCurves.flatMap(\.values).filter(\.isFinite)
        let rightDataMin = min(rightValues.min() ?? 0, rightAxisMinRange?.min ?? .infinity)
        let rightDataMax = max(rightValues.max() ?? 1, rightAxisMinRange?.max ?? -.infinity)
        let rightRange = hasRightAxis ? NiceAxisRange.range(min: rightDataMin, max: rightDataMax, targetTicks: 5) : leftRange

        func xPixel(_ x: Double) -> CGFloat {
            let span = max(xRange.max - xRange.min, 1e-12)
            return plotRect.minX + CGFloat((x - xRange.min) / span) * plotRect.width
        }
        func yPixel(_ y: Double, range: NiceAxisRange) -> CGFloat {
            let span = max(range.max - range.min, 1e-12)
            return plotRect.minY + CGFloat((y - range.min) / span) * plotRect.height
        }

        // Horizontal gridlines (left axis) + its tick labels.
        ctx.setStrokeColor(Self.gridColor.cgColor)
        ctx.setLineWidth(0.5)
        for tick in leftRange.ticks {
            let py = yPixel(tick, range: leftRange)
            ctx.move(to: CGPoint(x: plotRect.minX, y: py))
            ctx.addLine(to: CGPoint(x: plotRect.maxX, y: py))
            ctx.strokePath()
            drawText(formatAxisTick(tick), at: CGPoint(x: plotRect.minX - 4, y: py), attrs: tickAttrs,
                     hAlign: .right, vCenter: true)
        }

        // X axis tick labels (no vertical gridlines -- the horizontal ones already orient the eye).
        for tick in xRange.ticks {
            let px = xPixel(tick)
            drawText(formatAxisTick(tick), at: CGPoint(x: px, y: plotRect.minY - 12), attrs: tickAttrs, hAlign: .center)
        }

        if let xAxisLabel {
            drawText(xAxisLabel, at: CGPoint(x: plotRect.midX, y: bounds.minY + 6), attrs: tickAttrs, hAlign: .center)
        }

        if hasRightAxis {
            for tick in rightRange.ticks {
                let py = yPixel(tick, range: rightRange)
                drawText(formatAxisTick(tick), at: CGPoint(x: plotRect.maxX + 4, y: py), attrs: tickAttrs,
                         hAlign: .left, vCenter: true)
            }
        }

        ctx.setStrokeColor(Self.axisColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(plotRect)

        // Curves, clipped to the plot area so an out-of-range point doesn't draw over the margins.
        ctx.saveGState()
        ctx.clip(to: plotRect)
        let palette = ChartPalette.colors
        for (index, curve) in curves.enumerated() {
            let range = curve.axis == .left ? leftRange : rightRange
            let path = CGMutablePath()
            var started = false
            for (i, x) in xValues.enumerated() {
                guard i < curve.values.count, curve.values[i].isFinite else { continue }
                let point = CGPoint(x: xPixel(x), y: yPixel(curve.values[i], range: range))
                if started {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    started = true
                }
            }
            ctx.saveGState()
            ctx.setStrokeColor(palette[index % palette.count].cgColor)
            ctx.setLineWidth(1.5)
            if curve.dashed {
                ctx.setLineDash(phase: 0, lengths: [4, 3])
            }
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()

        drawLegend(rows: legendRows, palette: palette, attrs: legendAttrs)
    }

    private struct LegendEntry {
        let curveIndex: Int
        let curve: ChartCurve
    }

    /// Greedily wraps curve entries (swatch + label) into as many rows as needed to fit
    /// `availableWidth`, in curve order -- a new row starts only when the *next* entry wouldn't
    /// fit, matching ordinary word-wrap rather than trying to balance row lengths.
    private func legendRows(attrs: [NSAttributedString.Key: Any], availableWidth: CGFloat) -> [[LegendEntry]] {
        guard !curves.isEmpty else { return [] }
        let swatchWidth: CGFloat = 14
        let entrySpacing: CGFloat = 12
        let labelGap: CGFloat = 4

        var rows: [[LegendEntry]] = [[]]
        var currentRowWidth: CGFloat = 0
        for (index, curve) in curves.enumerated() {
            let labelWidth = (curve.label as NSString).size(withAttributes: attrs).width
            let entryWidth = swatchWidth + labelGap + labelWidth
            let isFirstInRow = rows[rows.count - 1].isEmpty
            let neededWidth = isFirstInRow ? entryWidth : currentRowWidth + entrySpacing + entryWidth
            if neededWidth > availableWidth, !isFirstInRow {
                rows.append([])
                currentRowWidth = entryWidth
            } else {
                currentRowWidth = neededWidth
            }
            rows[rows.count - 1].append(LegendEntry(curveIndex: index, curve: curve))
        }
        return rows
    }

    private func drawLegend(rows: [[LegendEntry]], palette: [NSColor], attrs: [NSAttributedString.Key: Any]) {
        let swatchWidth: CGFloat = 14
        let entrySpacing: CGFloat = 12
        let labelGap: CGFloat = 4

        for (rowIndex, row) in rows.enumerated() {
            let y = bounds.maxY - 6 - Self.legendRowHeight * CGFloat(rowIndex) - Self.legendRowHeight / 2
            var x = bounds.maxX - 4

            // Right-to-left layout (simplest way to right-align a row of variable-width entries
            // without a second width measurement pass).
            for entry in row.reversed() {
                let textSize = (entry.curve.label as NSString).size(withAttributes: attrs)
                x -= textSize.width
                (entry.curve.label as NSString).draw(at: CGPoint(x: x, y: y - textSize.height / 2), withAttributes: attrs)
                x -= labelGap
                let color = palette[entry.curveIndex % palette.count]
                let swatchPath = NSBezierPath()
                swatchPath.move(to: NSPoint(x: x - swatchWidth, y: y))
                swatchPath.line(to: NSPoint(x: x, y: y))
                swatchPath.lineWidth = entry.curve.dashed ? 1.0 : 1.5
                if entry.curve.dashed {
                    swatchPath.setLineDash([4, 3], count: 2, phase: 0)
                }
                color.setStroke()
                swatchPath.stroke()
                x -= swatchWidth + entrySpacing
            }
        }
    }

    private enum TextHAlign { case left, center, right }

    private func drawText(_ text: String, at point: CGPoint, attrs: [NSAttributedString.Key: Any], hAlign: TextHAlign,
                           vCenter: Bool = false) {
        let size = (text as NSString).size(withAttributes: attrs)
        var origin = point
        switch hAlign {
        case .left: break
        case .center: origin.x -= size.width / 2
        case .right: origin.x -= size.width
        }
        if vCenter {
            origin.y -= size.height / 2
        }
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }
}
