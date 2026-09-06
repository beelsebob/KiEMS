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
        let color: NSColor = backgroundStyle == .emphasized ? .white : .labelColor
        NetNameFormatting.draw(segments, in: bounds, color: color)
    }
}
