import AppKit

/// A simplified Smith chart (unit circle + real axis + a dashed VSWR-margin circle + the S11(f)
/// trace) -- no charting library has a polar/Smith chart type as standard, and forcing a generic
/// X/Y chart to keep a strict 1:1 aspect ratio (required for a circle to look like a circle) tends
/// to fight the API, so this is a small custom Core Graphics view instead, in the same spirit as
/// LineChartView. Mirrors postprocess.cpp's own renderSmith exactly (same "hand-drawn simplified
/// Smith chart" tradeoff that file's header already documents -- a unit circle + axis + VSWR circle
/// + trace, not skrf's full constant-R/X grid), styled to match LineChartView's own look (grid
/// color/weight, legend font, default curve color) so it reads as part of the same chart family.
public final class SmithChartView: NSView {
    private var reGamma: [Double] = []
    private var imGamma: [Double] = []
    private var vswrMarginGamma: Double = 0
    private var portLabel = ""

    private static let gridColor = NSColor.gray.withAlphaComponent(0.6)
    private static let traceColor = ChartPalette.colors[5]
    private static let legendFont = NSFont.systemFont(ofSize: 10)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 260).isActive = true
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

        let inset: CGFloat = 16
        let plotRect = bounds.insetBy(dx: inset, dy: inset + 18) // headroom at top for the legend
        let radius = min(plotRect.width, plotRect.height) / 2
        let center = CGPoint(x: bounds.midX, y: plotRect.midY)

        func point(re: Double, im: Double) -> CGPoint {
            CGPoint(x: center.x + CGFloat(re) * radius, y: center.y + CGFloat(im) * radius)
        }

        ctx.setStrokeColor(Self.gridColor.cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.move(to: point(re: -1, im: 0))
        ctx.addLine(to: point(re: 1, im: 0))
        ctx.strokePath()

        let marginRadius = CGFloat(vswrMarginGamma) * radius
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.strokeEllipse(in: CGRect(x: center.x - marginRadius, y: center.y - marginRadius,
                                      width: marginRadius * 2, height: marginRadius * 2))
        ctx.restoreGState()

        if !reGamma.isEmpty {
            ctx.setStrokeColor(Self.traceColor.cgColor)
            ctx.setLineWidth(1.5)
            let path = CGMutablePath()
            path.move(to: point(re: reGamma[0], im: imGamma[0]))
            for i in 1..<reGamma.count {
                path.addLine(to: point(re: reGamma[i], im: imGamma[i]))
            }
            ctx.addPath(path)
            ctx.strokePath()
        }

        drawLegend(in: bounds)
    }

    private func drawLegend(in bounds: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.legendFont, .foregroundColor: NSColor.labelColor]
        let swatchWidth: CGFloat = 16
        let rowHeight: CGFloat = 14
        var y = bounds.maxY - rowHeight
        let entries: [(NSColor, Bool, String)] = [
            (Self.traceColor, false, portLabel),
            (NSColor.systemRed, true, "VSWR margin"),
        ]
        for (color, dashed, text) in entries {
            let textSize = (text as NSString).size(withAttributes: attrs)
            let totalWidth = swatchWidth + 4 + textSize.width
            let x = bounds.maxX - totalWidth - 4
            let midY = y + rowHeight / 2

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
            y -= rowHeight
        }
    }
}
