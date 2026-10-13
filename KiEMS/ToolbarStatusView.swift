import Cocoa

/// The Xcode-style status display centred in a document window's toolbar: the linked KiCad project
/// (with the button to choose another) and board file, what the document is doing right now, and how
/// many failed tests and warnings its simulations have. DocumentWindowController owns every bit of
/// state shown here; this view only lays it out.
final class ToolbarStatusView: NSView {
    let projectPathControl = NSPathControl()
    let projectSelectionButton = NSButton()
    let boardPopUp = NSPopUpButton()

    /// Fired by clicking the failed-test or warning count.
    var onShowErrors: (() -> Void)?
    var onShowWarnings: (() -> Void)?

    private let boardSeparator = NSImageView()
    private let activitySeparator = NSBox()
    private let spinner = NSProgressIndicator()
    private let activityLabel = NSTextField(labelWithString: "")
    private let progressLine = ProgressLineView()
    private let errorCount = IssueCountView(symbolName: "exclamationmark.octagon.fill", tint: .systemRed)
    private let warningCount = IssueCountView(symbolName: "exclamationmark.triangle.fill", tint: .systemYellow)

    private static let height: CGFloat = 34
    private static let minimumWidth: CGFloat = 320
    private static let maximumWidth: CGFloat = 720
    /// How much of the toolbar's width the sidebar section (traffic lights, run buttons) takes --
    /// the display fits beside it. Set by the window controller as the sidebar resizes.
    var leadingToolbarWidth: CGFloat = 228
    /// Clearance at both ends of the remaining toolbar section.
    private static let margins: CGFloat = 32
    /// NSToolbar gives a custom view item its fitting width and never stretches it, so the display
    /// sets its own: as wide as the window leaves room for, within the limits above.
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: Self.minimumWidth)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.height / 2
        glass.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = content
        addSubview(glass)

        projectPathControl.placeholderString = "Choose a KiCad project"
        projectPathControl.controlSize = .small
        projectPathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        projectPathControl.focusRingType = .none
        projectPathControl.backgroundColor = .clear
        // When space runs short the path gives way first (it collapses its middle components), down
        // to a comfortable width; then the activity message; then the path again, to its minimum.
        projectPathControl.setContentCompressionResistancePriority(.defaultLow - 3, for: .horizontal)
        projectPathControl.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        projectSelectionButton.isBordered = false
        projectSelectionButton.imagePosition = .imageOnly
        projectSelectionButton.imageScaling = .scaleProportionallyDown
        projectSelectionButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Choose a project")
        projectSelectionButton.contentTintColor = .secondaryLabelColor
        projectSelectionButton.toolTip = "Choose a KiCad project or board"
        projectSelectionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        boardSeparator.image = NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil)
        boardSeparator.contentTintColor = .tertiaryLabelColor

        boardPopUp.controlSize = .small
        boardPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        boardPopUp.isBordered = false
        boardPopUp.toolTip = "Board file"
        boardPopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        boardPopUp.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        activitySeparator.boxType = .separator

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        activityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.setContentCompressionResistancePriority(.defaultLow - 2, for: .horizontal)
        activityLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)

        errorCount.onClick = { [weak self] in self?.onShowErrors?() }
        warningCount.onClick = { [weak self] in self?.onShowWarnings?() }

        let stack = NSStackView(views: [projectPathControl, projectSelectionButton, boardSeparator, boardPopUp,
                                        activitySeparator, spinner, activityLabel, warningCount, errorCount])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(10, after: boardPopUp)
        stack.setCustomSpacing(10, after: activitySeparator)
        stack.setCustomSpacing(10, after: activityLabel)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        progressLine.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(progressLine)

        // Between the path's and the activity message's compression resistance -- see above.
        let comfortablePathWidth = projectPathControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        comfortablePathWidth.priority = .defaultLow - 1
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            widthConstraint,

            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            projectPathControl.heightAnchor.constraint(equalToConstant: 16),
            projectPathControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            comfortablePathWidth,
            projectSelectionButton.widthAnchor.constraint(equalToConstant: 16),
            projectSelectionButton.heightAnchor.constraint(equalToConstant: 16),
            boardSeparator.widthAnchor.constraint(equalToConstant: 8),
            boardPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            activitySeparator.heightAnchor.constraint(equalToConstant: 16),
            activityLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

            // Along the bottom edge, clear of the rounded ends -- like Xcode's build progress.
            progressLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.height / 2),
            progressLine.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.height / 2),
            progressLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -2),
            progressLine.heightAnchor.constraint(equalToConstant: 2),
        ])

        setBoardVisible(false)
        setActivity("", isBusy: false, fraction: nil)
        setIssueCounts(errors: 0, warnings: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize(_:)),
                                               name: NSWindow.didResizeNotification, object: window)
        updateWidth()
    }

    // Full screen moves the toolbar into a window of its own, which only reports after resizing.
    @objc private func windowDidResize(_ notification: Notification) {
        updateWidth()
    }

    private func updateWidth() {
        guard let window else { return }
        updateWidth(forWindowWidth: window.frame.width)
    }

    /// Shrinks with the window down to a usable minimum, but never sprawls across a wide one. Called
    /// by the window's delegate before a resize, so the toolbar lays out with the new width.
    func updateWidth(forWindowWidth windowWidth: CGFloat) {
        let available = windowWidth - leadingToolbarWidth - Self.margins
        let width = min(max(available, Self.minimumWidth), Self.maximumWidth).rounded()
        if widthConstraint.constant != width {
            widthConstraint.constant = width
        }
    }

    /// Shows `url` as text-only breadcrumbs: icons on every component made a narrow path an
    /// unreadable row of folder glyphs.
    func setProjectURL(_ url: URL?) {
        projectPathControl.url = url
        for item in projectPathControl.pathItems {
            item.image = nil
        }
        projectPathControl.toolTip = url?.path(percentEncoded: false)
    }

    /// The board picker only means anything once a project has been chosen.
    func setBoardVisible(_ visible: Bool) {
        boardSeparator.isHidden = !visible
        boardPopUp.isHidden = !visible
    }

    /// `isBusy` spins the activity indicator; `fraction` (0...1) fills the progress line along the
    /// bottom edge, which is hidden when nil.
    func setActivity(_ text: String, isBusy: Bool, fraction: Double?) {
        activityLabel.stringValue = text
        activityLabel.toolTip = text.isEmpty ? nil : text
        activityLabel.isHidden = text.isEmpty
        activitySeparator.isHidden = text.isEmpty && !isBusy
        spinner.isHidden = !isBusy
        if isBusy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        progressLine.fraction = fraction
    }

    /// Each count is hidden at zero, as in Xcode.
    func setIssueCounts(errors: Int, warnings: Int) {
        errorCount.set(count: errors, description: errors == 1 ? "1 failed test" : "\(errors) failed tests")
        warningCount.set(count: warnings, description: warnings == 1 ? "1 warning" : "\(warnings) warnings")
    }
}

/// A clickable count with its glyph, e.g. "⚠ 3" -- hidden at zero.
private final class IssueCountView: NSView {
    var onClick: (() -> Void)?

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(symbolName: String, tint: NSColor) {
        super.init(frame: .zero)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.contentTintColor = tint
        imageView.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .regular)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(count: Int, description: String) {
        label.stringValue = "\(count)"
        isHidden = count == 0
        toolTip = "\(description). Click to show the next one."
        setAccessibilityLabel(description)
    }

    // In the title bar a click on a non-opaque view would otherwise drag the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A thin, determinate progress line -- hidden while `fraction` is nil.
private final class ProgressLineView: NSView {
    var fraction: Double? {
        didSet {
            isHidden = fraction == nil
            needsLayout = true
        }
    }

    private let fill = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let clamped = min(max(fraction ?? 0, 0), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        fill.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = bounds.height / 2
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}
