import Cocoa

/// A full-width strip pinned to the top of a pipeline-stage content view (Geometry/Simulation
/// Results) explaining why what's below it isn't current -- yellow for results that are shown but
/// out of date, blue for a stage that has never run -- with a single action button at its trailing
/// end to (re)run that stage. Hidden (and so collapsed to zero height by its owner's constraints)
/// whenever the content is up to date.
final class StatusBannerView: NSView {
    enum Style {
        case warning
        case info
        case success

        var tint: NSColor {
            switch self {
            case .warning: return .systemYellow
            case .info: return .systemBlue
            case .success: return .systemGreen
            }
        }
    }

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let bottomBorder = NSView()
    private var action: (() -> Void)?
    private var style: Style = .info
    /// Bumped by every show/hide, so a pending showTransient dismissal can tell it's been superseded.
    private var generation = 0
    /// While a transient banner is up, plain hide() calls (every owner refresh starts with one)
    /// leave it alone -- it dismisses itself, or is replaced by show() or hide(force: true).
    private var isTransient = false
    /// Collapses the banner to nothing while hidden, so whatever its owner anchors below it moves
    /// up to the top of the view. The content's own vertical constraints sit just below required
    /// so this one wins without an unsatisfiable-constraints warning.
    private lazy var collapsedHeight = heightAnchor.constraint(equalToConstant: 0)

    override var isHidden: Bool {
        didSet { collapsedHeight.isActive = isHidden }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bottomBorder.wantsLayer = true

        messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageLabel.textColor = .labelColor
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.bezelStyle = .push
        actionButton.target = self
        actionButton.action = #selector(actionButtonPressed)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.translatesAutoresizingMaskIntoConstraints = false

        bottomBorder.translatesAutoresizingMaskIntoConstraints = false

        addSubview(messageLabel)
        addSubview(actionButton)
        addSubview(bottomBorder)
        let labelTop = messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        let labelBottom = messageLabel.bottomAnchor.constraint(equalTo: bottomBorder.topAnchor, constant: -10)
        let buttonTop = actionButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6)
        let borderHeight = bottomBorder.heightAnchor.constraint(equalToConstant: 1)
        for constraint in [labelTop, labelBottom, buttonTop, borderHeight] {
            constraint.priority = .required - 1
        }
        NSLayoutConstraint.activate([
            labelTop, labelBottom, buttonTop, borderHeight,
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: messageLabel.trailingAnchor, constant: 12),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actionButton.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),

            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        clipsToBounds = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the banner. `details`, if any, are listed as bullets under `title`.
    func show(style: Style, title: String, details: [String] = [], buttonTitle: String,
              action: @escaping () -> Void) {
        let text = ([title] + details.map { "• \($0)" }).joined(separator: "\n")
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                                range: NSRange(location: 0, length: (title as NSString).length))
        messageLabel.attributedStringValue = attributed
        actionButton.title = buttonTitle
        self.action = action
        generation += 1
        isTransient = false
        self.style = style
        applyColors()
        alphaValue = 1
        isHidden = false
        actionButton.isHidden = false
    }

    /// Shows a message with no button for `duration` seconds, then fades and slides it away.
    func showTransient(style: Style, title: String, duration: TimeInterval = 5) {
        show(style: style, title: title, buttonTitle: "") {}
        actionButton.isHidden = true
        isTransient = true
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.generation == token else { return }
            self.animateOut(token: token)
        }
    }

    private func animateOut(token: Int) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            animator().alphaValue = 0
            collapsedHeight.isActive = true
            superview?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, self.generation == token else { return }
            self.hide(force: true)
            self.alphaValue = 1
        })
    }

    /// CGColors don't follow appearance changes on their own -- re-resolved here for light/dark.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = style.tint.withAlphaComponent(0.2).cgColor
            bottomBorder.layer?.backgroundColor = style.tint.cgColor
        }
    }

    func hide(force: Bool = false) {
        guard force || !isTransient else { return }
        generation += 1
        isTransient = false
        isHidden = true
        action = nil
    }

    @objc private func actionButtonPressed() {
        action?()
    }
}
