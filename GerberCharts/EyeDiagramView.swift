import AppKit

/// Dense two-unit-interval eye plot. Every received bit slice is drawn on the same axis with a
/// translucent stroke; crossings and the open eye emerge from the accumulated traces rather than
/// from a precomputed envelope.
public final class EyeDiagramView: NSView {
    private var timeUI: [Double] = []
    private var traces: [[Double]] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 300).isActive = true
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setData(timeUI: [Double], traces: [[Double]]) {
        self.timeUI = timeUI
        self.traces = traces.filter { $0.count == timeUI.count }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard timeUI.count > 1, !traces.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

        let plot = bounds.insetBy(dx: 52, dy: 30).offsetBy(dx: 8, dy: 8)
        guard plot.width > 1, plot.height > 1 else { return }

        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).fill()

        let finiteValues = traces.flatMap { $0 }.filter(\.isFinite)
        guard let rawMin = finiteValues.min(), let rawMax = finiteValues.max() else { return }
        let magnitude = max(abs(rawMin), abs(rawMax), 1e-12) * 1.08
        let xMin = timeUI.first ?? -0.5
        let xMax = timeUI.last ?? 1.5

        func point(x: Double, y: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((x - xMin) / (xMax - xMin)) * plot.width,
                    y: plot.midY + CGFloat(y / magnitude) * plot.height / 2)
        }

        context.saveGState()
        context.addPath(CGPath(roundedRect: plot, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.clip()

        context.setLineWidth(0.5)
        context.setStrokeColor(NSColor.gridColor.withAlphaComponent(0.55).cgColor)
        for x in stride(from: -0.5, through: 1.5, by: 0.5) {
            let p = point(x: x, y: 0)
            context.move(to: CGPoint(x: p.x, y: plot.minY))
            context.addLine(to: CGPoint(x: p.x, y: plot.maxY))
        }
        for fraction in [-1.0, -0.5, 0.0, 0.5, 1.0] {
            let p = point(x: 0, y: fraction * magnitude)
            context.move(to: CGPoint(x: plot.minX, y: p.y))
            context.addLine(to: CGPoint(x: plot.maxX, y: p.y))
        }
        context.strokePath()

        context.setLineWidth(0.8)
        context.setLineJoin(.round)
        context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.075).cgColor)
        for trace in traces {
            context.beginPath()
            for i in timeUI.indices where trace[i].isFinite {
                let p = point(x: timeUI[i], y: trace[i])
                if i == 0 { context.move(to: p) } else { context.addLine(to: p) }
            }
            context.strokePath()
        }
        context.restoreGState()

        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).stroke()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for x in stride(from: -0.5, through: 1.5, by: 0.5) {
            let text = String(format: "%.1f", x) as NSString
            let size = text.size(withAttributes: labelAttributes)
            let p = point(x: x, y: 0)
            text.draw(at: CGPoint(x: p.x - size.width / 2, y: plot.minY - size.height - 4),
                      withAttributes: labelAttributes)
        }
        for y in [-magnitude, 0, magnitude] {
            let text = String(format: "%.3g", y) as NSString
            let size = text.size(withAttributes: labelAttributes)
            let p = point(x: 0, y: y)
            text.draw(at: CGPoint(x: plot.minX - size.width - 6, y: p.y - size.height / 2),
                      withAttributes: labelAttributes)
        }

        let axis = "Unit intervals" as NSString
        let axisSize = axis.size(withAttributes: labelAttributes)
        axis.draw(at: CGPoint(x: plot.midX - axisSize.width / 2, y: bounds.minY + 2),
                  withAttributes: labelAttributes)
    }
}
