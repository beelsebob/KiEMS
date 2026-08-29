import Cocoa

/// A plain, Auto-Layout-friendly label for a formatted net/net-class/footprint/pin name (see
/// NetNameFormatting) -- for anywhere a net name needs showing outside a table/outline view, where
/// NetNameCellView's NSTableCellView-based, frame-positioned approach doesn't fit. Read-only: this
/// has no NSTableCellView machinery and isn't wired up as any kind of control, just a label.
final class NetNameView: NSView {
    private var segments: [NetNameFormatting.Segment] = []

    func configure(name: String, font: NSFont) {
        segments = NetNameFormatting.segments(for: name, font: font)
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NetNameFormatting.draw(segments, in: bounds, color: .labelColor)
    }
}
