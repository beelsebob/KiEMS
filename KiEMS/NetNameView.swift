import Cocoa

/// A plain, Auto-Layout-friendly label for a formatted net/net-class/footprint/pin name (see
/// NetNameFormatting) -- for anywhere a net name needs showing outside a table/outline view, where
/// NetNameCellView's NSTableCellView-based, frame-positioned approach doesn't fit. Read-only: this
/// has no NSTableCellView machinery and isn't wired up as any kind of control, just a label.
final class NetNameView: NSView {
    private var segments: [NetNameFormatting.Segment] = []
    private var textColor: NSColor = .labelColor

    func configure(name: String, font: NSFont, color: NSColor = .labelColor) {
        segments = NetNameFormatting.segments(for: name, font: font)
        textColor = color
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard !segments.isEmpty else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        return NetNameFormatting.size(for: segments)
    }

    /// NSStackView's `.firstBaseline` alignment only works for a custom-drawn view when the view
    /// reports where its text baseline actually is. NSView's default baseline is effectively its
    /// bottom edge, which made a NetNameView sit lower than an adjacent NSTextField heading.
    override var firstBaselineOffsetFromTop: CGFloat {
        guard let tallestFont = segments.max(by: {
            ($0.font.ascender - $0.font.descender) < ($1.font.ascender - $1.font.descender)
        })?.font else {
            return super.firstBaselineOffsetFromTop
        }
        let lineHeight = tallestFont.ascender - tallestFont.descender
        let verticalInset = max(0, (intrinsicContentSize.height - lineHeight) / 2)
        return verticalInset + tallestFont.ascender
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NetNameFormatting.draw(segments, in: bounds, color: textColor)
    }
}
