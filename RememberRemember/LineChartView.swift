import AppKit

/// Which Y axis a curve is plotted against -- `.right` only has any effect if at least one curve
/// in the same LineChartView uses it, at which point a second axis (with its own independently
/// nice-numbered range) is drawn.
public enum ChartAxisSide {
    case left
    case right
}

/// How values are positioned along a chart's X axis. A logarithmic axis accepts only positive
/// values and spaces equal ratios equally; non-positive samples are omitted from the plot.
public enum ChartXAxisScale {
    case linear
    case logarithmic
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
    /// Stroke width in points -- defaults to the same 1.5 every curve has always drawn at. A
    /// thinner value (e.g. for one of several individual measurements shown alongside their own
    /// average) visually recedes behind curves at the default weight without needing a separate
    /// drawing pass or reduced opacity.
    public var lineWidth: CGFloat
    /// Uses a bold legend label. The stroke itself remains controlled independently by lineWidth.
    public var emphasized: Bool

    public init(label: String, values: [Double], axis: ChartAxisSide = .left, dashed: Bool = false,
                lineWidth: CGFloat = 1.5, emphasized: Bool = false) {
        self.label = label
        self.values = values
        self.axis = axis
        self.dashed = dashed
        self.lineWidth = lineWidth
        self.emphasized = emphasized
    }
}

/// A shaded min/max envelope drawn beneath every curve -- e.g. the range several individual
/// measurements fell within at each X value, with their average drawn as an ordinary ChartCurve on
/// top. `low`/`high` share the chart's own X values and left axis, like a ChartCurve's `values`.
public struct ChartBand {
    public var low: [Double]
    public var high: [Double]

    public init(low: [Double], high: [Double]) {
        self.low = low
        self.high = high
    }
}

/// A uniformly sampled intensity profile painted vertically behind a chart. Intensities are
/// normalized by the renderer and represented by fill opacity, making this suitable for showing a
/// time-domain excitation's absolute magnitude without pretending it has a single hard boundary.
public struct ChartXIntensityBand {
    public var startX: Double
    public var endX: Double
    public var intensities: [Double]

    public init(startX: Double, endX: Double, intensities: [Double]) {
        self.startX = startX
        self.endX = endX
        self.intensities = intensities
    }
}

/// A basic, self-contained X/Y line chart: gridlines, tick labels, a legend, one or more
/// color-coded curves, and an optional secondary (right) Y axis -- pure Core Graphics, no external
/// dependency. Built specifically to replace DGCharts (a third-party charting library), which was
/// confirmed, through careful bisection, to corrupt this app's window layout under real use. It
/// supports the small set of interactions useful for inspecting results: hover readouts and
/// trackpad pan/zoom, while deliberately avoiding the much larger charting dependency.
public final class LineChartView: NSView {
    private var xValues: [Double] = []
    private var curves: [ChartCurve] = []
    private var band: ChartBand?
    private var xAxisMinRange: (min: Double, max: Double)?
    private var xIntensityBand: ChartXIntensityBand?
    private var leftAxisMinRange: (min: Double, max: Double)?
    private var rightAxisMinRange: (min: Double, max: Double)?
    private var xAxisScale: ChartXAxisScale = .linear
    private var xAxisLabel: String?
    private var leftYAxisLabel: String?
    private var rightYAxisLabel: String?

    /// Data extents do not change while the user is manipulating the viewport. Cache their
    /// nice-numbered ranges so a magnification event does not synchronously rescan every sample.
    private var baseXRange = NiceAxisRange.range(min: 0, max: 1, targetTicks: 6)
    private var baseLeftRange = NiceAxisRange.range(min: 0, max: 1, targetTicks: 5)
    private var baseRightRange = NiceAxisRange.range(min: 0, max: 1, targetTicks: 5)

    /// A normalized window into an automatically calculated axis range. Keeping the viewport in
    /// normalized coordinates means a live graph can append samples without throwing away the
    /// user's current zoom.
    private struct ViewportInterval {
        var start = 0.0
        var span = 1.0

        var isFull: Bool { start <= 1e-9 && span >= 1 - 1e-9 }

        mutating func zoom(by factor: Double, around anchor: Double) {
            let clampedAnchor = min(max(anchor, 0), 1)
            let valueAtAnchor = start + clampedAnchor * span
            span = min(max(span * factor, 0.001), 1)
            start = valueAtAnchor - clampedAnchor * span
            clamp()
        }

        mutating func pan(by fractionOfView: Double) {
            start += fractionOfView * span
            clamp()
        }

        mutating func clamp() {
            span = min(max(span, 0.001), 1)
            start = min(max(start, 0), 1 - span)
        }
    }

    private var xViewport = ViewportInterval()
    private var yViewport = ViewportInterval()
    /// Kept by curve index so live `setData` updates retain the user's legend choices without
    /// coupling visibility to the curve's display label.
    private var disabledCurveIndices: Set<Int> = []
    private var trackingArea: NSTrackingArea?
    private var hoverLocation: CGPoint?

    private static let tickFont = NSFont.systemFont(ofSize: 9)
    private static let legendFont = NSFont.systemFont(ofSize: 10)
    private static let emphasizedLegendFont = NSFont.boldSystemFont(ofSize: 10)
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
    public func setData(xValues: [Double], curves: [ChartCurve], band: ChartBand? = nil,
                         leftAxisMinRange: (min: Double, max: Double)? = nil,
                         rightAxisMinRange: (min: Double, max: Double)? = nil,
                         xAxisMinRange: (min: Double, max: Double)? = nil,
                         xIntensityBand: ChartXIntensityBand? = nil,
                         xAxisScale: ChartXAxisScale = .linear,
                         xAxisLabel: String? = nil,
                         leftYAxisLabel: String? = nil,
                         rightYAxisLabel: String? = nil) {
        self.xValues = xValues
        self.curves = curves
        self.band = band
        self.leftAxisMinRange = leftAxisMinRange
        self.rightAxisMinRange = rightAxisMinRange
        self.xAxisMinRange = xAxisMinRange
        self.xIntensityBand = xIntensityBand
        self.xAxisScale = xAxisScale
        self.xAxisLabel = xAxisLabel
        self.leftYAxisLabel = leftYAxisLabel
        self.rightYAxisLabel = rightYAxisLabel
        disabledCurveIndices = disabledCurveIndices.filter { curves.indices.contains($0) }
        updateBaseRanges()
        hoverLocation = nil
        needsDisplay = true
    }

    /// Recalculate data-dependent ranges only when new chart data arrives. Iterating directly also
    /// avoids the large temporary arrays previously made by `flatMap`/`filter` during interaction.
    private func updateBaseRanges() {
        func include(_ value: Double, in extent: inout (min: Double, max: Double)?) {
            guard value.isFinite else { return }
            if let current = extent {
                extent = (Swift.min(current.min, value), Swift.max(current.max, value))
            } else {
                extent = (value, value)
            }
        }

        func scaledX(_ value: Double) -> Double? {
            guard value.isFinite else { return nil }
            switch xAxisScale {
            case .linear:
                return value
            case .logarithmic:
                return value > 0 ? log10(value) : nil
            }
        }

        var xExtent: (min: Double, max: Double)?
        for value in xValues {
            if let value = scaledX(value) { include(value, in: &xExtent) }
        }
        if let xAxisMinRange {
            if let value = scaledX(xAxisMinRange.min) { include(value, in: &xExtent) }
            if let value = scaledX(xAxisMinRange.max) { include(value, in: &xExtent) }
        }
        let x = xExtent ?? (0, 1)
        baseXRange = NiceAxisRange.range(min: x.min, max: x.max, targetTicks: 6)

        var leftExtent: (min: Double, max: Double)?
        var rightExtent: (min: Double, max: Double)?
        for curve in curves {
            if curve.axis == .left {
                for value in curve.values { include(value, in: &leftExtent) }
            } else {
                for value in curve.values { include(value, in: &rightExtent) }
            }
        }
        if let band {
            for value in band.low { include(value, in: &leftExtent) }
            for value in band.high { include(value, in: &leftExtent) }
        }
        if let leftAxisMinRange {
            include(leftAxisMinRange.min, in: &leftExtent)
            include(leftAxisMinRange.max, in: &leftExtent)
        }
        if let rightAxisMinRange {
            include(rightAxisMinRange.min, in: &rightExtent)
            include(rightAxisMinRange.max, in: &rightExtent)
        }

        let left = leftExtent ?? (0, 1)
        baseLeftRange = NiceAxisRange.range(min: left.min, max: left.max, targetTicks: 5)
        if curves.contains(where: { $0.axis == .right }) {
            let right = rightExtent ?? (0, 1)
            baseRightRange = NiceAxisRange.range(min: right.min, max: right.max, targetTicks: 5)
        } else {
            baseRightRange = baseLeftRange
        }
    }

    public override var isFlipped: Bool { false }

    public override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func mouseMoved(with event: NSEvent) {
        hoverLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hoverLocation = nil
        needsDisplay = true
    }

    /// Pinching zooms the X axis around the pointer by default. Holding Option switches the same
    /// gesture to the Y axis; in either case the value under the user's fingers remains anchored.
    public override func magnify(with event: NSEvent) {
        guard let geometry = chartGeometry() else { return }
        let location = convert(event.locationInWindow, from: nil)
        let factor = exp(-Double(event.magnification) * 2)
        if event.modifierFlags.contains(.option) {
            let yAnchor = Double((location.y - geometry.plotRect.minY) / geometry.plotRect.height)
            yViewport.zoom(by: factor, around: yAnchor)
        } else {
            let xAnchor = Double((location.x - geometry.plotRect.minX) / geometry.plotRect.width)
            xViewport.zoom(by: factor, around: xAnchor)
        }
        // Nearest-line lookup walks all curves. Avoid doing it behind the user's fingers on every
        // frame; restore the readout when the gesture finishes.
        hoverLocation = event.phase == .ended || event.phase == .cancelled ? location : nil
        needsDisplay = true
    }

    /// Two-finger trackpad scrolling pans a zoomed graph. At the automatic full extent, pass the
    /// event to the surrounding results scroller so ordinary page scrolling continues to work.
    public override func scrollWheel(with event: NSEvent) {
        guard !xViewport.isFull || !yViewport.isFull, let geometry = chartGeometry() else {
            super.scrollWheel(with: event)
            return
        }
        xViewport.pan(by: -Double(event.scrollingDeltaX / geometry.plotRect.width))
        yViewport.pan(by: Double(event.scrollingDeltaY / geometry.plotRect.height))
        hoverLocation = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    /// Double-clicking is a quick way back to the chart's automatic full-data range.
    public override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, let curveIndex = legendCurve(at: location) {
            if disabledCurveIndices.contains(curveIndex) {
                disabledCurveIndices.remove(curveIndex)
            } else {
                disabledCurveIndices.insert(curveIndex)
            }
            hoverLocation = nil
            needsDisplay = true
            return
        }
        // The second mouse-down of a double-click over the legend must not leak through and reset
        // the viewport after the first click toggled the curve.
        if legendCurve(at: location) != nil { return }
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        xViewport = ViewportInterval()
        yViewport = ViewportInterval()
        needsDisplay = true
    }

    private static let legendRowHeight: CGFloat = 14

    private struct ChartGeometry {
        let plotRect: CGRect
        let xRange: NiceAxisRange
        let leftRange: NiceAxisRange
        let rightRange: NiceAxisRange
    }

    private func scaledX(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        switch xAxisScale {
        case .linear:
            return value
        case .logarithmic:
            return value > 0 ? log10(value) : nil
        }
    }

    private func unscaledX(_ value: Double) -> Double {
        switch xAxisScale {
        case .linear:
            return value
        case .logarithmic:
            return pow(10, value)
        }
    }

    /// Tick positions are returned in the chart's internal coordinate system. For a logarithmic
    /// range spanning at least a decade, use the conventional 1/2/5 subdivisions; narrower views
    /// use evenly spaced logarithmic ticks so zooming remains informative.
    private func xTicks(for range: NiceAxisRange) -> [Double] {
        guard xAxisScale == .logarithmic else { return range.ticks }
        let span = range.max - range.min
        guard span >= 1 else { return range.ticks }

        var ticks: [Double] = []
        let firstDecade = Int(floor(range.min))
        let lastDecade = Int(ceil(range.max))
        for decade in firstDecade...lastDecade {
            for multiplier in [1.0, 2.0, 5.0] {
                let position = Double(decade) + log10(multiplier)
                if position >= range.min - 1e-12, position <= range.max + 1e-12 {
                    ticks.append(position)
                }
            }
        }
        return ticks
    }

    private func chartGeometry() -> ChartGeometry? {
        guard !xValues.isEmpty else { return nil }
        let hasRightAxis = curves.contains { $0.axis == .right }

        let leftMargin: CGFloat = 42
        let rightMargin: CGFloat = hasRightAxis ? 42 : 10
        let legendRows = legendRows(availableWidth: bounds.width - 8)
        let topMargin: CGFloat = legendRows.isEmpty ? 8 : 6 + CGFloat(legendRows.count) * Self.legendRowHeight + 6
        let bottomMargin: CGFloat = xAxisLabel == nil ? 16 : 28
        let plotRect = CGRect(x: bounds.minX + leftMargin, y: bounds.minY + bottomMargin,
                              width: bounds.width - leftMargin - rightMargin,
                              height: bounds.height - topMargin - bottomMargin)
        guard plotRect.width > 1, plotRect.height > 1 else { return nil }

        func visibleRange(_ base: NiceAxisRange, viewport: ViewportInterval, targetTicks: Int) -> NiceAxisRange {
            guard !viewport.isFull else { return base }
            let baseSpan = base.max - base.min
            let min = base.min + viewport.start * baseSpan
            let max = min + viewport.span * baseSpan
            // Do not feed the viewport bounds back through `range`, which expands them to nice
            // numbers and makes continuous gestures jump between quantized scales/offsets. Only
            // borrow its nicely rounded tick interval; the visible domain remains exact.
            let niceTicks = NiceAxisRange.range(min: min, max: max, targetTicks: targetTicks)
            return NiceAxisRange(min: min, max: max, step: niceTicks.step)
        }

        return ChartGeometry(
            plotRect: plotRect,
            xRange: visibleRange(baseXRange, viewport: xViewport, targetTicks: 6),
            leftRange: visibleRange(baseLeftRange, viewport: yViewport, targetTicks: 5),
            rightRange: visibleRange(baseRightRange, viewport: yViewport, targetTicks: 5))
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, let geometry = chartGeometry() else { return }

        let hasRightAxis = curves.contains { $0.axis == .right }

        let tickAttrs: [NSAttributedString.Key: Any] = [.font: Self.tickFont, .foregroundColor: NSColor.secondaryLabelColor]
        // Curve labels can be long ("Response at U8 pin 4") -- the legend wraps to as many rows as
        // it needs (see legendRows()), so the reserved top margin has to match however many rows
        // that turned out to be, with a bit of extra breathing room below the last row so its text
        // doesn't run into the plot border.
        let legendRows = legendRows(availableWidth: bounds.width - 8)
        let plotRect = geometry.plotRect
        let xRange = geometry.xRange
        let leftRange = geometry.leftRange
        let rightRange = geometry.rightRange

        func xPixel(_ x: Double) -> CGFloat? {
            guard let x = scaledX(x) else { return nil }
            let span = max(xRange.max - xRange.min, 1e-12)
            return plotRect.minX + CGFloat((x - xRange.min) / span) * plotRect.width
        }
        func yPixel(_ y: Double, range: NiceAxisRange) -> CGFloat {
            let span = max(range.max - range.min, 1e-12)
            return plotRect.minY + CGFloat((y - range.min) / span) * plotRect.height
        }

        if xAxisScale == .linear, let intensityBand = xIntensityBand,
           intensityBand.endX > intensityBand.startX,
           intensityBand.intensities.count >= 2,
           let peak = intensityBand.intensities.filter(\.isFinite).max(), peak > 0 {
            let firstPixel = max(Int(plotRect.minX.rounded(.down)),
                                 Int((xPixel(intensityBand.startX) ?? plotRect.minX).rounded(.down)))
            let lastPixel = min(Int(plotRect.maxX.rounded(.up)),
                                Int((xPixel(intensityBand.endX) ?? plotRect.maxX).rounded(.up)))
            if lastPixel > firstPixel {
                for pixel in firstPixel..<lastPixel {
                    let x = xRange.min + Double(CGFloat(pixel) - plotRect.minX) /
                        Double(plotRect.width) * (xRange.max - xRange.min)
                    let position = (x - intensityBand.startX) / (intensityBand.endX - intensityBand.startX)
                    guard position >= 0, position <= 1 else { continue }
                    let samplePosition = position * Double(intensityBand.intensities.count - 1)
                    let lower = Int(samplePosition.rounded(.down))
                    let upper = min(lower + 1, intensityBand.intensities.count - 1)
                    let fraction = samplePosition - Double(lower)
                    let magnitude = intensityBand.intensities[lower] * (1 - fraction) +
                        intensityBand.intensities[upper] * fraction
                    guard magnitude.isFinite, magnitude > 0 else { continue }
                    ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.28 * magnitude / peak).cgColor)
                    ctx.fill(CGRect(x: CGFloat(pixel), y: plotRect.minY,
                                    width: 1, height: plotRect.height))
                }
            }
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
        for tick in xTicks(for: xRange) {
            let rawTick = unscaledX(tick)
            guard let px = xPixel(rawTick) else { continue }
            drawText(formatAxisTick(rawTick), at: CGPoint(x: px, y: plotRect.minY - 12), attrs: tickAttrs,
                     hAlign: .center)
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

        // Band + curves, clipped to the plot area so an out-of-range point doesn't draw over the
        // margins.
        ctx.saveGState()
        ctx.clip(to: plotRect)

        if let band, !band.low.isEmpty, band.low.count == band.high.count {
            let path = CGMutablePath()
            var started = false
            for (i, x) in xValues.enumerated() {
                guard i < band.low.count, band.low[i].isFinite, let px = xPixel(x) else { continue }
                let point = CGPoint(x: px, y: yPixel(band.low[i], range: leftRange))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            for i in stride(from: xValues.count - 1, through: 0, by: -1) {
                guard i < band.high.count, band.high[i].isFinite, let px = xPixel(xValues[i]) else { continue }
                path.addLine(to: CGPoint(x: px, y: yPixel(band.high[i], range: leftRange)))
            }
            path.closeSubpath()
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }

        let palette = ChartPalette.colors
        for (index, curve) in curves.enumerated() {
            guard !disabledCurveIndices.contains(index) else { continue }
            let range = curve.axis == .left ? leftRange : rightRange
            let path = CGMutablePath()
            var started = false
            var pointCount = 0
            var onlyPoint = CGPoint.zero
            for (i, x) in xValues.enumerated() {
                guard i < curve.values.count, curve.values[i].isFinite, let px = xPixel(x) else {
                    started = false
                    continue
                }
                let point = CGPoint(x: px, y: yPixel(curve.values[i], range: range))
                pointCount += 1
                onlyPoint = point
                if started {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    started = true
                }
            }
            ctx.saveGState()
            let color = palette[index % palette.count].cgColor
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(curve.lineWidth)
            if curve.dashed {
                ctx.setLineDash(phase: 0, lengths: [4, 3])
            }
            if pointCount == 1 {
                // A live series can legitimately contain just its first sample for several seconds;
                // a move-only path has no visible stroke, so render that one value as a small point.
                ctx.fillEllipse(in: CGRect(x: onlyPoint.x - 2, y: onlyPoint.y - 2, width: 4, height: 4))
            } else {
                ctx.addPath(path)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()

        drawLegend(rows: legendRows, palette: palette)

        // Draw the readout last so it remains legible if the selected point is close to the legend.
        if let hoverLocation,
           let hover = nearestCurvePoint(to: hoverLocation, geometry: geometry, maximumDistance: 10) {
            drawHover(hover, in: geometry, context: ctx)
        }
    }

    private struct HoverPoint {
        let curveIndex: Int
        let x: Double
        let y: Double
        let screenPoint: CGPoint
        let distance: CGFloat
    }

    /// Finds the closest point on the rendered polyline, interpolating between samples. This is
    /// intentionally geometric rather than just choosing the closest X sample: steep transitions
    /// and overlapping curves consequently select the line that is actually under the pointer.
    private func nearestCurvePoint(to location: CGPoint, geometry: ChartGeometry,
                                   maximumDistance: CGFloat) -> HoverPoint? {
        guard geometry.plotRect.insetBy(dx: -maximumDistance, dy: -maximumDistance).contains(location) else {
            return nil
        }

        func xPixel(_ x: Double) -> CGFloat? {
            guard let x = scaledX(x) else { return nil }
            return geometry.plotRect.minX + CGFloat((x - geometry.xRange.min) /
                max(geometry.xRange.max - geometry.xRange.min, 1e-12)) * geometry.plotRect.width
        }
        func yPixel(_ y: Double, range: NiceAxisRange) -> CGFloat {
            geometry.plotRect.minY + CGFloat((y - range.min) /
                max(range.max - range.min, 1e-12)) * geometry.plotRect.height
        }

        var nearest: HoverPoint?
        for (curveIndex, curve) in curves.enumerated() {
            guard !disabledCurveIndices.contains(curveIndex) else { continue }
            let range = curve.axis == .left ? geometry.leftRange : geometry.rightRange
            let count = min(xValues.count, curve.values.count)
            guard count > 0 else { continue }

            if count == 1, curve.values[0].isFinite, let px = xPixel(xValues[0]) {
                let point = CGPoint(x: px, y: yPixel(curve.values[0], range: range))
                let distance = hypot(point.x - location.x, point.y - location.y)
                if distance <= maximumDistance, distance < nearest?.distance ?? .infinity {
                    nearest = HoverPoint(curveIndex: curveIndex, x: xValues[0], y: curve.values[0],
                                         screenPoint: point, distance: distance)
                }
                continue
            }

            for index in 0..<(count - 1) {
                let x0 = xValues[index]
                let x1 = xValues[index + 1]
                let y0 = curve.values[index]
                let y1 = curve.values[index + 1]
                guard y0.isFinite, y1.isFinite, let px0 = xPixel(x0), let px1 = xPixel(x1) else { continue }

                let p0 = CGPoint(x: px0, y: yPixel(y0, range: range))
                let p1 = CGPoint(x: px1, y: yPixel(y1, range: range))
                let dx = p1.x - p0.x
                let dy = p1.y - p0.y
                let lengthSquared = dx * dx + dy * dy
                let projection: CGFloat
                if lengthSquared > 0 {
                    projection = min(max(((location.x - p0.x) * dx + (location.y - p0.y) * dy) /
                        lengthSquared, 0), 1)
                } else {
                    projection = 0
                }
                let point = CGPoint(x: p0.x + projection * dx, y: p0.y + projection * dy)
                guard geometry.plotRect.insetBy(dx: -1, dy: -1).contains(point) else { continue }
                let distance = hypot(point.x - location.x, point.y - location.y)
                if distance <= maximumDistance, distance < nearest?.distance ?? .infinity {
                    let scaledX0 = scaledX(x0)!
                    let scaledX1 = scaledX(x1)!
                    nearest = HoverPoint(curveIndex: curveIndex,
                                         x: unscaledX(scaledX0 + Double(projection) * (scaledX1 - scaledX0)),
                                         y: y0 + Double(projection) * (y1 - y0),
                                         screenPoint: point, distance: distance)
                }
            }
        }
        return nearest
    }

    private func drawHover(_ hover: HoverPoint, in geometry: ChartGeometry, context: CGContext) {
        let color = ChartPalette.colors[hover.curveIndex % ChartPalette.colors.count]

        context.saveGState()
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(0.5)
        context.setLineDash(phase: 0, lengths: [2, 3])
        context.move(to: CGPoint(x: hover.screenPoint.x, y: geometry.plotRect.minY))
        context.addLine(to: CGPoint(x: hover.screenPoint.x, y: geometry.plotRect.maxY))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: hover.screenPoint.x - 3.5, y: hover.screenPoint.y - 3.5,
                                       width: 7, height: 7))
        context.setStrokeColor(NSColor.windowBackgroundColor.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(x: hover.screenPoint.x - 3.5, y: hover.screenPoint.y - 3.5,
                                         width: 7, height: 7))
        context.restoreGState()

        let curve = curves[hover.curveIndex]
        let yAxisLabel = curve.axis == .left ? leftYAxisLabel : rightYAxisLabel
        let text = NSMutableAttributedString(
            string: curve.label + "\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(
            string: "\(formatAxisReadout(label: xAxisLabel, fallbackName: "X", value: hover.x))    " +
                formatAxisReadout(label: yAxisLabel, fallbackName: "Y", value: hover.y),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        let textSize = text.boundingRect(with: CGSize(width: 320, height: 80),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let padding = CGSize(width: 7, height: 5)
        let boxSize = CGSize(width: ceil(textSize.width) + padding.width * 2,
                             height: ceil(textSize.height) + padding.height * 2)
        var boxOrigin = CGPoint(x: hover.screenPoint.x + 10, y: hover.screenPoint.y + 10)
        if boxOrigin.x + boxSize.width > bounds.maxX - 4 {
            boxOrigin.x = hover.screenPoint.x - boxSize.width - 10
        }
        if boxOrigin.y + boxSize.height > bounds.maxY - 4 {
            boxOrigin.y = hover.screenPoint.y - boxSize.height - 10
        }
        boxOrigin.x = max(bounds.minX + 4, boxOrigin.x)
        boxOrigin.y = max(bounds.minY + 4, boxOrigin.y)
        let box = CGRect(origin: boxOrigin, size: boxSize)

        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSColor.separatorColor.setStroke()
        let background = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        background.lineWidth = 0.5
        background.fill()
        background.stroke()
        text.draw(with: box.insetBy(dx: padding.width, dy: padding.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private func formatHoverValue(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        return magnitude >= 100_000 || magnitude < 0.0001
            ? String(format: "%.5e", value)
            : String(format: "%.6g", value)
    }

    /// Axis captions elsewhere in the UI use either "Magnitude (dB)" or "Relative energy [dB]".
    /// Split that existing presentation metadata once for the hover readout so the quantity name
    /// replaces the old generic "Value" label and the unit follows the number itself.
    private func formatAxisReadout(label: String?, fallbackName: String, value: Double) -> String {
        let caption = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = caption.isEmpty ? fallbackName : caption
        var unit: String?

        for (opening, closing) in [("[", "]"), ("(", ")")] where caption.hasSuffix(closing) {
            guard let openingRange = caption.range(of: opening, options: .backwards) else { continue }
            let unitStart = openingRange.upperBound
            let unitEnd = caption.index(before: caption.endIndex)
            let candidateUnit = caption[unitStart..<unitEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateName = caption[..<openingRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidateName.isEmpty, !candidateUnit.isEmpty {
                name = candidateName
                unit = candidateUnit
            }
            break
        }

        let suffix = unit.map { " \($0)" } ?? ""
        return "\(name): \(formatHoverValue(value))\(suffix)"
    }

    private struct LegendEntry {
        let curveIndex: Int
        let curve: ChartCurve
    }

    /// Greedily wraps curve entries (swatch + label) into as many rows as needed to fit
    /// `availableWidth`, in curve order -- a new row starts only when the *next* entry wouldn't
    /// fit, matching ordinary word-wrap rather than trying to balance row lengths.
    private func legendAttributes(for curve: ChartCurve, enabled: Bool = true) -> [NSAttributedString.Key: Any] {
        [.font: curve.emphasized ? Self.emphasizedLegendFont : Self.legendFont,
         .foregroundColor: enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor]
    }

    private func legendRows(availableWidth: CGFloat) -> [[LegendEntry]] {
        guard !curves.isEmpty else { return [] }
        let swatchWidth: CGFloat = 14
        let entrySpacing: CGFloat = 12
        let labelGap: CGFloat = 4

        var rows: [[LegendEntry]] = [[]]
        var currentRowWidth: CGFloat = 0
        // Emphasized curves are the primary result, so place them at the leading edge of the
        // legend regardless of the data/drawing order (which still controls colour and z-order).
        let legendOrder = curves.indices.sorted { lhs, rhs in
            if curves[lhs].emphasized != curves[rhs].emphasized {
                return curves[lhs].emphasized
            }
            return lhs < rhs
        }
        for index in legendOrder {
            let curve = curves[index]
            let attrs = legendAttributes(for: curve)
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

    private func drawLegend(rows: [[LegendEntry]], palette: [NSColor]) {
        let swatchWidth: CGFloat = 14
        let entrySpacing: CGFloat = 12
        let labelGap: CGFloat = 4

        for (rowIndex, row) in rows.enumerated() {
            let y = bounds.maxY - 6 - Self.legendRowHeight * CGFloat(rowIndex) - Self.legendRowHeight / 2
            var x = bounds.maxX - 4

            // Right-to-left layout (simplest way to right-align a row of variable-width entries
            // without a second width measurement pass).
            for entry in row.reversed() {
                let enabled = !disabledCurveIndices.contains(entry.curveIndex)
                let attrs = legendAttributes(for: entry.curve, enabled: enabled)
                let textSize = (entry.curve.label as NSString).size(withAttributes: attrs)
                x -= textSize.width
                (entry.curve.label as NSString).draw(at: CGPoint(x: x, y: y - textSize.height / 2), withAttributes: attrs)
                x -= labelGap
                let sourceColor = palette[entry.curveIndex % palette.count]
                let color = enabled ? sourceColor : desaturatedLegendColor(sourceColor)
                let swatchPath = NSBezierPath()
                swatchPath.move(to: NSPoint(x: x - swatchWidth, y: y))
                swatchPath.line(to: NSPoint(x: x, y: y))
                swatchPath.lineWidth = entry.curve.dashed ? 1.0 : entry.curve.lineWidth
                if entry.curve.dashed {
                    swatchPath.setLineDash([4, 3], count: 2, phase: 0)
                }
                color.setStroke()
                swatchPath.stroke()
                x -= swatchWidth + entrySpacing
            }
        }
    }

    /// Returns the curve whose complete legend entry (swatch plus text) contains `location`.
    /// This mirrors drawLegend's right-aligned, right-to-left layout exactly, including wrapping.
    private func legendCurve(at location: CGPoint) -> Int? {
        let rows = legendRows(availableWidth: bounds.width - 8)
        let swatchWidth: CGFloat = 14
        let entrySpacing: CGFloat = 12
        let labelGap: CGFloat = 4

        for (rowIndex, row) in rows.enumerated() {
            let y = bounds.maxY - 6 - Self.legendRowHeight * CGFloat(rowIndex) - Self.legendRowHeight / 2
            var x = bounds.maxX - 4
            for entry in row.reversed() {
                let textWidth = (entry.curve.label as NSString)
                    .size(withAttributes: legendAttributes(for: entry.curve)).width
                let entryMaxX = x
                let entryMinX = x - textWidth - labelGap - swatchWidth
                let hitRect = CGRect(x: entryMinX - 3,
                                     y: y - Self.legendRowHeight / 2,
                                     width: entryMaxX - entryMinX + 6,
                                     height: Self.legendRowHeight)
                if hitRect.contains(location) { return entry.curveIndex }
                x = entryMinX - entrySpacing
            }
        }
        return nil
    }

    private func desaturatedLegendColor(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return color.withAlphaComponent(0.55)
        }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(deviceHue: hue, saturation: saturation * 0.2,
                       brightness: brightness, alpha: alpha * 0.7)
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
