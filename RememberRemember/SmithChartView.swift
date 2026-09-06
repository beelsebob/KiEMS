import AppKit

/// A normalized-impedance Smith chart. The grid is generated from the reflection-coefficient
/// transform Γ = (z - 1) / (z + 1): constant resistance values form circles and constant reactance
/// values form the familiar arcs meeting at Γ=1. Keeping the construction in impedance space is
/// less error-prone than maintaining a collection of hand-tuned Core Graphics arc angles.
public final class SmithChartView: NSView {
    private var reGamma: [Double] = []
    private var imGamma: [Double] = []
    private var vswrMarginGamma: Double = 0
    private var portLabel = ""

    private static let minorGridColor = NSColor.gray.withAlphaComponent(0.24)
    private static let majorGridColor = NSColor.gray.withAlphaComponent(0.48)
    private static let labelColor = NSColor.secondaryLabelColor
    private static let traceColor = ChartPalette.colors[5]
    private static let gridLabelFont = NSFont.systemFont(ofSize: 8)
    private static let legendFont = NSFont.systemFont(ofSize: 10)
    private static let resistanceValues = [0.2, 0.5, 1.0, 2.0, 5.0]
    private static let reactanceValues = [0.2, 0.5, 1.0, 2.0, 5.0]
    private static let sideInset: CGFloat = 18
    private static let bottomInset: CGFloat = 14
    private static let legendHeight: CGFloat = 24
    private static let plotLegendGap: CGFloat = 8

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // The containing results stack determines our width. Derive the height from it so the
        // Smith circle consumes that full width while retaining room for the legend above it.
        let verticalDecoration = Self.bottomInset + Self.legendHeight + Self.plotLegendGap
        heightAnchor.constraint(
            equalTo: widthAnchor,
            constant: verticalDecoration - Self.sideInset * 2
        ).isActive = true
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setData(port: Int, reGamma: [Double], imGamma: [Double], vswrMarginGamma: Double) {
        self.reGamma = reGamma
        self.imGamma = imGamma
        self.vswrMarginGamma = vswrMarginGamma
        portLabel = "S\(port + 1)\(port + 1)"
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let plotRect = CGRect(x: bounds.minX + Self.sideInset, y: bounds.minY + Self.bottomInset,
                              width: bounds.width - Self.sideInset * 2,
                              height: bounds.height - Self.bottomInset - Self.legendHeight - Self.plotLegendGap)
        let radius = min(plotRect.width, plotRect.height) / 2
        let center = CGPoint(x: bounds.midX, y: plotRect.midY)
        guard radius > 2 else { return }

        func point(re: Double, im: Double) -> CGPoint {
            CGPoint(x: center.x + CGFloat(re) * radius, y: center.y + CGFloat(im) * radius)
        }

        // Keep every curve within |Γ|≤1. In addition to making the grid exact at the rim, this
        // prevents an unstable S-parameter sample from drawing through a neighbouring chart.
        let smithCircle = CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.addEllipse(in: smithCircle)
        ctx.clip()

        ctx.setStrokeColor(Self.majorGridColor.cgColor)
        ctx.setLineWidth(0.8)
        for resistance in Self.resistanceValues {
            let gridRadius = radius / CGFloat(1 + resistance)
            let gridCenterX = center.x + radius * CGFloat(resistance / (1 + resistance))
            ctx.strokeEllipse(in: CGRect(x: gridCenterX - gridRadius, y: center.y - gridRadius,
                                         width: gridRadius * 2, height: gridRadius * 2))
        }

        func gamma(resistance: Double, reactance: Double) -> CGPoint {
            let denominator = (resistance + 1) * (resistance + 1) + reactance * reactance
            return point(re: (resistance * resistance + reactance * reactance - 1) / denominator,
                         im: 2 * reactance / denominator)
        }

        ctx.setStrokeColor(Self.minorGridColor.cgColor)
        ctx.setLineWidth(0.7)
        for magnitude in Self.reactanceValues {
            for reactance in [magnitude, -magnitude] {
                let path = CGMutablePath()
                path.move(to: gamma(resistance: 0, reactance: reactance))
                // Logarithmic resistance sampling gives the tight turn near Γ=1 enough points
                // without wasting most samples on the visually gentle part of the arc.
                for sample in 0...180 {
                    let exponent = -4.0 + 8.0 * Double(sample) / 180.0
                    path.addLine(to: gamma(resistance: pow(10, exponent), reactance: reactance))
                }
                path.addLine(to: point(re: 1, im: 0))
                ctx.addPath(path)
                ctx.strokePath()
            }
        }

        ctx.setStrokeColor(Self.majorGridColor.cgColor)
        ctx.setLineWidth(0.9)
        ctx.move(to: point(re: -1, im: 0))
        ctx.addLine(to: point(re: 1, im: 0))
        ctx.strokePath()

        let marginRadius = min(1, max(0, CGFloat(vswrMarginGamma))) * radius
        if marginRadius > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokeEllipse(in: CGRect(x: center.x - marginRadius, y: center.y - marginRadius,
                                          width: marginRadius * 2, height: marginRadius * 2))
            ctx.restoreGState()
        }

        let count = min(reGamma.count, imGamma.count)
        if count > 0 {
            ctx.setStrokeColor(Self.traceColor.cgColor)
            ctx.setLineWidth(1.8)
            let path = CGMutablePath()
            var pathStarted = false
            for i in 0..<count where reGamma[i].isFinite && imGamma[i].isFinite {
                let tracePoint = point(re: reGamma[i], im: imGamma[i])
                if pathStarted {
                    path.addLine(to: tracePoint)
                } else {
                    path.move(to: tracePoint)
                    pathStarted = true
                }
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // Redraw the rim after clipping so it stays crisp and visually closes the grid.
        ctx.setStrokeColor(Self.majorGridColor.cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))

        drawGridLabels(center: center, radius: radius)
        drawLegend(in: CGRect(x: bounds.minX, y: bounds.maxY - Self.legendHeight,
                              width: bounds.width, height: Self.legendHeight))
    }

    private func drawGridLabels(center: CGPoint, radius: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.gridLabelFont,
            .foregroundColor: Self.labelColor,
        ]
        for resistance in Self.resistanceValues {
            let x = center.x + radius * CGFloat((resistance - 1) / (resistance + 1))
            let text = formatGridValue(resistance)
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: x - size.width / 2, y: center.y + 3), withAttributes: attrs)
        }

        for reactance in Self.reactanceValues {
            let denominator = 1 + reactance * reactance
            let x = center.x + radius * CGFloat((reactance * reactance - 1) / denominator)
            let y = radius * CGFloat(2 * reactance / denominator)
            for sign: CGFloat in [1, -1] {
                let text = (sign > 0 ? "+j" : "−j") + formatGridValue(reactance)
                let size = (text as NSString).size(withAttributes: attrs)
                let labelY = center.y + sign * y + (sign > 0 ? 2 : -size.height - 2)
                (text as NSString).draw(at: CGPoint(x: x - size.width / 2, y: labelY), withAttributes: attrs)
            }
        }
    }

    private func formatGridValue(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func drawLegend(in bounds: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.legendFont, .foregroundColor: NSColor.labelColor]
        let swatchWidth: CGFloat = 16
        let gap: CGFloat = 16
        let entries: [(NSColor, Bool, String)] = [
            (Self.traceColor, false, portLabel),
            (NSColor.systemRed, true, "VSWR margin"),
        ]
        let widths = entries.map { swatchWidth + 4 + ($0.2 as NSString).size(withAttributes: attrs).width }
        var x = bounds.midX - (widths.reduce(0, +) + gap * CGFloat(entries.count - 1)) / 2
        for (color, dashed, text) in entries {
            let textSize = (text as NSString).size(withAttributes: attrs)
            let midY = bounds.midY

            let swatchPath = NSBezierPath()
            swatchPath.move(to: NSPoint(x: x, y: midY))
            swatchPath.line(to: NSPoint(x: x + swatchWidth, y: midY))
            swatchPath.lineWidth = dashed ? 1.0 : 1.5
            if dashed {
                swatchPath.setLineDash([4, 3], count: 2, phase: 0)
            }
            color.setStroke()
            swatchPath.stroke()

            (text as NSString).draw(at: NSPoint(x: x + swatchWidth + 4, y: midY - textSize.height / 2), withAttributes: attrs)
            x += swatchWidth + 4 + textSize.width + gap
        }
    }
}
