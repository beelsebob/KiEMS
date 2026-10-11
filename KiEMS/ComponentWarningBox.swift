import AppKit

/// A selected component's SPICE-model and value warnings, as shown in the Info panel: one row per
/// warning with a caution sign in its yellow, then an optional note (the schematic still being
/// read, which isn't a problem) in neutral grey without one. Hidden when there's nothing to say.
final class ComponentWarningBox: NSBox {
    private let rows = NSStackView()
    private let textWidth: CGFloat

    /// `textWidth` is the widest a warning's text may wrap to, without the caution sign.
    init(textWidth: CGFloat) {
        self.textWidth = textWidth
        super.init(frame: .zero)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        boxType = .custom
        cornerRadius = 5
        titlePosition = .noTitle
        contentViewMargins = NSSize(width: 8, height: 6)
        contentView = rows
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ warnings: [String], note: String?) {
        for row in rows.arrangedSubviews { row.removeFromSuperview() }
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func row(_ text: String, color: NSColor, caution: Bool) -> NSView {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = font
            label.textColor = color
            label.preferredMaxLayoutWidth = textWidth - (caution ? 22 : 0)
            guard caution else { return label }
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: "Caution")!)
            icon.contentTintColor = color
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let stack = NSStackView(views: [icon, label])
            stack.orientation = .horizontal
            stack.alignment = .top
            stack.spacing = 6
            return stack
        }
        for warning in warnings {
            rows.addArrangedSubview(row(warning, color: .systemYellow, caution: true))
        }
        if let note {
            rows.addArrangedSubview(row(note, color: .secondaryLabelColor, caution: false))
        }
        let tint: NSColor = warnings.isEmpty ? .secondaryLabelColor : .systemYellow
        borderColor = tint
        fillColor = tint.withAlphaComponent(0.1)
        isHidden = warnings.isEmpty && note == nil
    }
}
