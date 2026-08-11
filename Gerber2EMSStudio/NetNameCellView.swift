import Cocoa

/// A custom NSOutlineView cell for a formatted net/net-class/footprint/pin name (see
/// NetNameFormatting). Needed specifically for the `~{...}` overline: sub/superscript is just an
/// NSAttributedString `.baselineOffset` attribute, which a plain NSTextField already renders fine,
/// but there's no built-in "overline" text attribute to lean on the same way -- it has to be drawn
/// by hand, positioned against each overlined segment's own on-screen x-range. The row's status
/// icon (see SourceListViewController.icon(for:)) lives in its own table column, not here -- see
/// SourceListIconCellView.
final class NetNameCellView: NSTableCellView {
    private var segments: [NetNameFormatting.Segment] = []

    func configure(name: String, font: NSFont) {
        segments = NetNameFormatting.segments(for: name, font: font)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !segments.isEmpty else { return }

        let color: NSColor = backgroundStyle == .emphasized ? .white : .labelColor
        let fullString = NSMutableAttributedString()
        for segment in segments {
            fullString.append(NSAttributedString(string: segment.text, attributes: [
                .font: segment.font,
                .baselineOffset: segment.baselineOffset,
                .foregroundColor: color,
            ]))
        }

        // draw(at:) positions the WHOLE string's bounding box at the given point -- that box's height
        // is set by whichever segment's font is tallest (almost always the base, non-sub/superscript
        // one), so vertical centering has to be measured against that, not any single segment.
        let lineHeight = segments.map { $0.font.ascender - $0.font.descender }.max() ?? 0
        let originY = (bounds.height - lineHeight) / 2
        fullString.draw(at: NSPoint(x: 0, y: originY))

        // Where the baseline actually sits: the tallest font's ascender below the box's top edge.
        let tallestFont = segments.max {
            ($0.font.ascender - $0.font.descender) < ($1.font.ascender - $1.font.descender)
        }?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let baselineY = originY + tallestFont.ascender

        // NSAttributedString has no API to ask "where did this substring land when drawn as part of
        // the larger string" -- measuring the width of each successive prefix gives the same answer
        // here, since each segment already carries its own font/attributes (a hard font-change
        // boundary, so there's no cross-segment kerning to throw the measurement off).
        //
        // A run of consecutive overlined segments (e.g. a negated section with a subscript in it,
        // "~{A_{B}}") gets ONE bar spanning the whole run, not one per segment -- otherwise a
        // subscript/superscript inside a negated section would get its own bar at a different height,
        // reading as a break in the line instead of one continuous overline. That bar sits at
        // whichever segment in the run needs the most clearance (the smallest -- i.e. topmost, since
        // this view is flipped -- glyphTopY among them), so it clears every segment's glyphs, sub or
        // super included.
        color.setStroke()
        var prefixLength = 0
        var startX: CGFloat = 0
        var runStartX: CGFloat?
        var runTopY: CGFloat = 0

        func flushRun(endingAt endX: CGFloat) {
            guard let runStartX else { return }
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: runStartX, y: runTopY))
            path.line(to: NSPoint(x: endX, y: runTopY))
            path.stroke()
        }

        for segment in segments {
            prefixLength += (segment.text as NSString).length
            let endX = fullString.attributedSubstring(from: NSRange(location: 0, length: prefixLength)).size().width
            if segment.isOverlined {
                // baselineOffset raises glyphs on screen for positive values, in both flipped and
                // non-flipped views -- in this flipped view (y grows downward), that's `-offset`.
                let glyphTopY = baselineY - segment.baselineOffset - segment.font.ascender
                if let existingRunStartX = runStartX {
                    runStartX = existingRunStartX
                    runTopY = min(runTopY, glyphTopY)
                } else {
                    runStartX = startX
                    runTopY = glyphTopY
                }
            } else {
                flushRun(endingAt: startX)
                runStartX = nil
            }
            startX = endX
        }
        flushRun(endingAt: startX)
    }
}
