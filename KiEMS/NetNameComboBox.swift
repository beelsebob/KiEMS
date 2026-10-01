import Cocoa

/// A combo box for net/net-class names: an editable text field plus a drop-down list. Needed
/// because NSComboBox's drop-down list only takes NSAttributedStrings, which can show
/// sub/superscript but have no way to draw the `~{...}` overline (see NetNameFormatting).
///
/// - While the field is being edited it shows exactly what the user typed (raw text, with
///   NSComboBox-style prefix auto-completion), and the drop-down list opens filtered to entries
///   matching it -- see `matches(_:typed:)`.
/// - When not being edited it shows the current value formatted.
/// - Every list entry is formatted, drawn by a NetNameCellView.
///
/// The list is a non-activating child panel rather than an NSMenu: an open NSMenu tracks the
/// keyboard itself, which would stop the user typing into the field while it's showing. Up/Down
/// move through it from the field, Return picks, Escape closes.
///
/// Changes are reported through `onCommit` with the raw name, plus the picked entry's tag when it
/// came from the list (nil when typed) -- validating typed text is left to the owner.
final class NetNameComboBox: NSControl, NSTextFieldDelegate {
    enum Entry {
        case heading(String)
        case separator
        case name(String, tag: Int)
    }

    var entries: [Entry] = [] {
        didSet {
            displayTexts = [:]
            if dropDownStorage?.isVisible == true { refreshDropDown(filter: currentFilter) }
        }
    }
    var onCommit: ((String, Int?) -> Void)?

    private let textField = FocusReportingTextField(string: "")
    private let menuButton = NSButton()
    private var dropDownStorage: NetNameDropDown?
    /// Created on first use -- a table full of these shouldn't each build a panel up front.
    private var dropDown: NetNameDropDown {
        if let dropDownStorage { return dropDownStorage }
        let dropDown = NetNameDropDown(owner: self)
        dropDownStorage = dropDown
        return dropDown
    }
    /// NetNameFormatting.displayText(for:) per name, filled in lazily as filtering needs it and
    /// kept across keystrokes (re-parsing every net's markup on each key press adds up on big boards).
    private var displayTexts: [String: String] = [:]
    private var lastTypedLength = 0
    private var clickAwayMonitor: Any?
    private var currentFilter: String?

    init(bordered: Bool = true) {
        super.init(frame: .zero)
        textField.cell = NetNameTextFieldCell(textCell: "")
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBordered = bordered
        textField.isBezeled = bordered
        textField.drawsBackground = bordered
        textField.usesSingleLineMode = true
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.delegate = self
        textField.onBecameFirstResponder = { [weak self] in self?.installClickAwayMonitor() }
        textField.target = self
        textField.action = #selector(textFieldAction)
        textField.translatesAutoresizingMaskIntoConstraints = false

        menuButton.isBordered = false
        menuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Show choices")
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.target = self
        menuButton.action = #selector(toggleDropDown)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(textField)
        addSubview(menuButton)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            menuButton.leadingAnchor.constraint(equalTo: textField.trailingAnchor, constant: 2),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var stringValue: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }

    override var font: NSFont? {
        get { textField.font }
        set { textField.font = newValue }
    }

    override var controlSize: NSControl.ControlSize {
        get { textField.controlSize }
        set {
            textField.controlSize = newValue
            menuButton.controlSize = newValue
        }
    }

    override var isEnabled: Bool {
        get { textField.isEnabled }
        set {
            textField.isEnabled = newValue
            menuButton.isEnabled = newValue
            if !newValue { dropDownStorage?.close() }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            dropDownStorage?.close()
            removeClickAwayMonitor()
        }
    }

    /// An entry matches typed text when its raw name contains it, or when the name as it reads
    /// once formatted does (so "V3.3" finds "V_{3.3}") -- both case-insensitively.
    private func matches(_ name: String, typed: String) -> Bool {
        if name.localizedCaseInsensitiveContains(typed) { return true }
        let displayText = displayTexts[name] ?? {
            let text = NetNameFormatting.displayText(for: name)
            displayTexts[name] = text
            return text
        }()
        return displayText.localizedCaseInsensitiveContains(typed)
    }

    private var names: [String] {
        entries.compactMap { if case .name(let name, _) = $0 { name } else { nil } }
    }

    // MARK: Typing

    /// Puts the cursor in the text field, ready for typing.
    func beginEditing() {
        window?.makeFirstResponder(textField)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        lastTypedLength = (textField.stringValue as NSString).length
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = textField.currentEditor() as? NSTextView else { return }
        let typed = editor.string
        let typedLength = (typed as NSString).length
        defer { lastTypedLength = typedLength }

        // The list filters on what was actually typed, never on a completion appended below.
        if typed.isEmpty {
            dropDownStorage?.close()
        } else {
            refreshDropDown(filter: typed)
        }

        // NSComboBox-style completion: only when the user grew the text (so backspacing over a
        // completion doesn't immediately re-complete), with the completed tail left selected.
        guard typedLength > lastTypedLength, !typed.isEmpty,
              editor.selectedRange().location == typedLength,
              let match = names.first(where: { $0.range(of: typed, options: [.anchored, .caseInsensitive]) != nil })
        else { return }
        let matchLength = (match as NSString).length
        guard matchLength > typedLength else { return }
        editor.string = match
        editor.setSelectedRange(NSRange(location: typedLength, length: matchLength - typedLength))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !dropDown.isVisible { refreshDropDown(filter: nil) }
            dropDown.moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard dropDownStorage?.isVisible == true else { return false }
            dropDownStorage?.moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard dropDownStorage?.isVisible == true, let (name, tag) = dropDownStorage?.selectedName else { return false }
            pick(name: name, tag: tag)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard dropDownStorage?.isVisible == true else { return false }
            dropDownStorage?.close()
            return true
        default:
            return false
        }
    }

    /// A click on something that doesn't take focus (empty window background, a label, another
    /// window) wouldn't otherwise end editing, so the edit -- and onCommit -- would never happen.
    /// While the field has focus, any click outside this combo box (and its drop-down) ends it.
    private func installClickAwayMonitor() {
        guard clickAwayMonitor == nil else { return }
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let window, textField.currentEditor() != nil else { return event }
            if event.window === dropDownStorage?.panelWindow { return event }
            if event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) {
                return event
            }
            window.makeFirstResponder(nil)
            if clickAwayMonitor != nil {
                // Ending editing didn't come back through controlTextDidEndEditing (AppKit can skip
                // it when nothing was typed), so commit here instead.
                removeClickAwayMonitor()
                onCommit?(textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), nil)
            }
            return event
        }
    }

    private func removeClickAwayMonitor() {
        if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
            self.clickAwayMonitor = nil
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        removeClickAwayMonitor()
        dropDownStorage?.close()
        onCommit?(textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    @objc private func textFieldAction() {
        onCommit?(textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    // MARK: Drop-down

    @objc private func toggleDropDown() {
        if dropDownStorage?.isVisible == true {
            dropDownStorage?.close()
        } else {
            refreshDropDown(filter: nil)
            dropDown.selectName(textField.stringValue)
        }
    }

    /// Shows the list (filtered, if `filter` is non-nil), or hides it when nothing matches.
    private func refreshDropDown(filter: String?) {
        currentFilter = filter
        var rows = entries
        if let filter {
            // Keep a heading/separator only if a matching name follows it (and, for a separator,
            // some name also precedes it).
            var filtered: [Entry] = []
            var pending: [Entry] = []
            for entry in entries {
                guard case .name(let name, _) = entry else {
                    pending.append(entry)
                    continue
                }
                guard matches(name, typed: filter) else { continue }
                filtered += pending.filter {
                    if case .separator = $0 { return !filtered.isEmpty } else { return true }
                }
                pending = []
                filtered.append(entry)
            }
            rows = filtered
        }
        guard rows.contains(where: { if case .name = $0 { return true } else { return false } }) else {
            dropDownStorage?.close()
            return
        }
        dropDown.show(rows: rows, below: self, font: textField.font ?? .systemFont(ofSize: NSFont.systemFontSize))
    }

    fileprivate func pick(name: String, tag: Int) {
        dropDownStorage?.close()
        textField.abortEditing()
        textField.stringValue = name
        onCommit?(name, tag)
    }

    fileprivate func isDropDownToggle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        return menuButton.bounds.contains(menuButton.convert(event.locationInWindow, from: nil))
    }
}

/// Reports gaining focus -- NSControl's own begin-editing notification only arrives with the
/// first keystroke, too late for a field that's focused and then left untouched.
private final class FocusReportingTextField: NSTextField {
    var onBecameFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecameFirstResponder?() }
        return became
    }
}

/// Shows the field's value formatted whenever it isn't being edited; while it is, the field
/// editor sits on top and shows the raw text the user is typing.
private final class NetNameTextFieldCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let name = stringValue
        guard !name.isEmpty, controlView.isFlipped,
              (controlView as? NSControl)?.currentEditor() == nil else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let frame = titleRect(forBounds: cellFrame).insetBy(dx: 2, dy: 0)
        let segments = NetNameFormatting.segments(for: name, font: font ?? NSFont.systemFont(ofSize: 0))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).addClip()
        NetNameFormatting.draw(segments, in: frame, color: isEnabled ? .labelColor : .disabledControlTextColor)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A borderless panel that never becomes key, so the combo box's field keeps keyboard focus while
/// the list is showing.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Always draws its selection in the accent color: the drop-down's panel is never key, which would
/// otherwise grey the selection out.
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

/// NetNameComboBox's drop-down list.
private final class NetNameDropDown: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let maxVisibleRows = 12
    private static let minimumWidth: CGFloat = 220
    /// NetNameCellInset's leading/trailing insets plus room for the vertical scroller.
    private static let nameHorizontalPadding: CGFloat = 14 + 8 + 16

    private weak var owner: NetNameComboBox?
    private let panel: NonActivatingPanel
    var panelWindow: NSWindow { panel }
    private let tableView = NSTableView()
    private var rows: [NetNameComboBox.Entry] = []
    private var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var clickMonitor: Any?
    private var anchorRect = NSRect.zero
    private var screenFrame: NSRect?
    /// Formatted width per name, measured lazily as rows come into view.
    private var measuredWidths: [String: CGFloat] = [:]

    init(owner: NetNameComboBox) {
        self.owner = owner
        panel = NonActivatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listScrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        scrollView.frame = background.bounds
        background.addSubview(scrollView)
        panel.contentView = background
    }

    var isVisible: Bool { panel.isVisible }

    func show(rows: [NetNameComboBox.Entry], below anchor: NSView, font: NSFont) {
        guard let window = anchor.window else { return }
        let previousSelection = selectedName
        let wasVisible = panel.isVisible
        if font != self.font { measuredWidths = [:] }
        self.rows = rows
        self.font = font
        tableView.reloadData()

        tableView.rowHeight = ceil(font.ascender - font.descender) + 6
        let height = CGFloat(min(rows.count, Self.maxVisibleRows)) * tableView.rowHeight + 8
        anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        // Height first (at the current width), so the table knows which rows are on screen before
        // the width is fitted to them.
        let width = wasVisible ? panel.frame.width : max(anchorRect.width, Self.minimumWidth)
        panel.setFrame(frame(width: width, height: height), display: false)
        tableView.enclosingScrollView?.frame = panel.contentView?.bounds.insetBy(dx: 0, dy: 4) ?? .zero

        if !wasVisible {
            window.addChildWindow(panel, ordered: .above)
            installClickMonitor()
        }
        if let previousSelection { selectName(previousSelection.0) }
        fitWidthToVisibleRows(allowShrinking: true, animated: wasVisible)
    }

    /// The list's frame for `width`, below the field and slid left as far as needed to keep it on
    /// screen (but never past the screen's left edge).
    private func frame(width: CGFloat, height: CGFloat) -> NSRect {
        var x = anchorRect.minX
        if let screenFrame {
            x = max(screenFrame.minX, min(x, screenFrame.maxX - width))
        }
        return NSRect(x: x, y: anchorRect.minY - height - 2, width: width, height: height)
    }

    /// Widens (or, when the filter changed, narrows) the list to fit the widest name currently
    /// scrolled into view. Only on-screen rows are ever measured (and each name only once) --
    /// measuring every net up front is what made opening the list on a large board hang -- so
    /// scrolling to longer names grows it further as they come into view.
    private func fitWidthToVisibleRows(allowShrinking: Bool, animated: Bool) {
        guard panel.isVisible, let clipView = tableView.enclosingScrollView?.contentView else { return }
        let visibleRows = tableView.rows(in: clipView.documentVisibleRect)
        var widest: CGFloat = 0
        if visibleRows.length > 0 {
            for row in visibleRows.location..<min(NSMaxRange(visibleRows), rows.count) {
                guard case .name(let name, _) = rows[row] else { continue }
                widest = max(widest, measuredWidth(of: name))
            }
        }
        var width = max(anchorRect.width, Self.minimumWidth, ceil(widest) + Self.nameHorizontalPadding)
        if let screenFrame { width = min(width, screenFrame.width) }
        if !allowShrinking { width = max(width, panel.frame.width) }
        guard abs(width - panel.frame.width) > 0.5 else { return }

        let target = frame(width: width, height: panel.frame.height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func measuredWidth(of name: String) -> CGFloat {
        if let width = measuredWidths[name] { return width }
        let width = NetNameFormatting.size(for: NetNameFormatting.segments(for: name, font: font)).width
        measuredWidths[name] = width
        return width
    }

    @objc private func listScrolled() {
        fitWidthToVisibleRows(allowShrinking: false, animated: true)
    }

    func close() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Clicks anywhere outside the list close it -- except on the combo box's own ▾ button, which
    /// toggles it itself.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, event.window !== panel else { return event }
            if owner?.isDropDownToggle(event) != true { close() }
            return event
        }
    }

    var selectedName: (String, Int)? {
        guard rows.indices.contains(tableView.selectedRow),
              case .name(let name, let tag) = rows[tableView.selectedRow] else { return nil }
        return (name, tag)
    }

    func selectName(_ name: String) {
        guard let row = rows.firstIndex(where: {
            if case .name(let candidate, _) = $0 { return candidate == name } else { return false }
        }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Moves to the next/previous name row, skipping headings and separators.
    func moveSelection(by step: Int) {
        var row = tableView.selectedRow < 0 ? (step > 0 ? -1 : rows.count) : tableView.selectedRow
        repeat {
            row += step
            guard rows.indices.contains(row) else { return }
        } while !isName(row)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func isName(_ row: Int) -> Bool {
        if case .name = rows[row] { return true } else { return false }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row), case .name(let name, let tag) = rows[row] else { return }
        owner?.pick(name: name, tag: tag)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isName(row) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }

    // Only ever called for rows scrolled into view, and each kind of cell is recycled via
    // makeView(withIdentifier:) -- frame-based rather than Auto Layout, so scrolling a few thousand
    // nets never builds or solves more than a screenful of views.
    private static let headingID = NSUserInterfaceItemIdentifier("heading")
    private static let separatorID = NSUserInterfaceItemIdentifier("separator")
    private static let nameID = NSUserInterfaceItemIdentifier("name")

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .heading(let title):
            let cell = tableView.makeView(withIdentifier: Self.headingID, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = Self.headingID
                let label = NSTextField(labelWithString: "")
                label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                label.textColor = .secondaryLabelColor
                label.frame = NSRect(x: 8, y: 0, width: 100, height: tableView.rowHeight)
                label.autoresizingMask = [.width, .height]
                cell.addSubview(label)
                cell.textField = label
                return cell
            }()
            cell.textField?.stringValue = title
            return cell
        case .separator:
            return tableView.makeView(withIdentifier: Self.separatorID, owner: nil) ?? {
                let cell = NSView()
                cell.identifier = Self.separatorID
                let separator = NSBox(frame: NSRect(x: 8, y: tableView.rowHeight / 2, width: 100, height: 1))
                separator.boxType = .separator
                separator.autoresizingMask = [.width, .minYMargin, .maxYMargin]
                cell.addSubview(separator)
                return cell
            }()
        case .name(let name, _):
            let cell = tableView.makeView(withIdentifier: Self.nameID, owner: nil) as? NetNameCellInset ?? {
                let cell = NetNameCellInset()
                cell.identifier = Self.nameID
                return cell
            }()
            cell.configure(name: name, font: font)
            return cell
        }
    }
}

/// Pads a NetNameCellView in from the row's leading edge (NetNameFormatting.draw starts at
/// bounds.minX), while forwarding the row's background style so selected text turns white.
private final class NetNameCellInset: NSTableCellView {
    private let cell = NetNameCellView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        cell.frame = bounds.insetBy(dx: 0, dy: 0)
        cell.frame.origin.x = 14
        cell.frame.size.width -= 22
        cell.autoresizingMask = [.width, .height]
        addSubview(cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, font: NSFont) {
        cell.configure(name: name, font: font)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { cell.backgroundStyle = backgroundStyle }
    }
}
