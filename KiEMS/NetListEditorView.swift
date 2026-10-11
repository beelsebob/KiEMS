import Cocoa

/// An editable list of net names, laid out like Xcode's Target Membership list: one bordered box
/// holding the list (with a "No Nets" placeholder while it's empty) and, under a hairline, a bar of
/// borderless add/remove/edit buttons separated by short vertical dividers. Each row picks its net
/// with a NetNameComboBox. Used for edge-terminated nets, both per simulation and in Board Setup.
final class NetListEditorView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let formFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let editButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No Nets")

    /// The listed names; a row added with (+) and not yet picked is "" (ignored downstream).
    var rows: [String] = [] {
        didSet { if !isCommittingRow { reload() } }
    }
    private var isCommittingRow = false

    /// Names a row may be set to -- typed text naming anything else reverts.
    var availableNames: [String] = [] {
        didSet { table.reloadData() }
    }

    var isEditable = true {
        didSet { reload() }
    }

    /// Fired with the full list after every edit made through this view.
    var onChange: (([String]) -> Void)?

    init() {
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("net"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // .plain and no backgrounds, as in SimulationListViewController: the box's own fill shows
        // through, rather than an opaque table fighting the glass panel this sits in.
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for (button, symbol, description, action) in [
            (addButton, "plus", "Add net", #selector(addRow)),
            (removeButton, "minus", "Remove net", #selector(removeRow)),
            (editButton, "pencil", "Edit net", #selector(editRow)),
        ] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        }
        func divider() -> NSView {
            let line = NSBox()
            line.boxType = .separator
            line.heightAnchor.constraint(equalToConstant: 10).isActive = true
            return line
        }
        let buttonBar = NSStackView(views: [addButton, divider(), removeButton, divider(), editButton])
        buttonBar.orientation = .horizontal
        buttonBar.alignment = .centerY
        buttonBar.spacing = 2
        buttonBar.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        buttonBar.translatesAutoresizingMaskIntoConstraints = false

        let barSeparator = NSBox()
        barSeparator.boxType = .separator
        barSeparator.translatesAutoresizingMaskIntoConstraints = false

        // Drawn by hand: an NSBox(.custom) border didn't show up at all inside the glass panel.
        let box = ListBoxView()
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        // Everything inside sits one point in from each edge (see the constraints below) so
        // nothing (selection highlight, separator) can overdraw the border.
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        for view in [scroll, emptyLabel, barSeparator, buttonBar] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 76),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            barSeparator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            barSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            barSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonBar.topAnchor.constraint(equalTo: barSeparator.bottomAnchor),
            buttonBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttonBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttonBar.heightAnchor.constraint(equalToConstant: 20),
        ])
        reload()
    }

    private func reload() {
        table.reloadData()
        table.isEnabled = isEditable
        updateControls()
    }

    /// The placeholder shows only while the list is empty; remove/edit act on the selected row, so
    /// (as in Xcode) they're only enabled while there is one.
    private func updateControls() {
        let hasSelection = isEditable && rows.indices.contains(table.selectedRow)
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.textColor = isEditable ? .secondaryLabelColor : .tertiaryLabelColor
        addButton.isEnabled = isEditable
        removeButton.isEnabled = hasSelection
        editButton.isEnabled = hasSelection
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let comboBox = NetNameComboBox(bordered: false)
        comboBox.controlSize = .small
        comboBox.font = Self.formFont
        comboBox.entries = availableNames.map { .name($0, tag: 0) }
        comboBox.stringValue = rows[row]
        comboBox.isEnabled = isEditable
        comboBox.onCommit = { [weak self, weak comboBox] name, _ in
            guard let self, let comboBox else { return }
            rowChanged(comboBox, name: name)
        }
        // Inset from the box's edges rather than filling the row, as Xcode's lists are.
        let cell = NSTableCellView()
        comboBox.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(comboBox)
        NSLayoutConstraint.activate([
            comboBox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            comboBox.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            comboBox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Accepts a picked menu item, or typed text naming an available net; anything else reverts.
    private func rowChanged(_ comboBox: NetNameComboBox, name: String) {
        // Looked up afresh rather than trusting the row captured when the cell was made: Return
        // and end-of-editing can both commit, and the first may already have removed a row.
        let row = table.row(for: comboBox)
        guard rows.indices.contains(row) else { return }
        guard availableNames.contains(name) else {
            if rows[row].isEmpty {
                // A row added with (+) and left without picking a net: drop it rather than keep a
                // blank entry around. Deferred so the table isn't edited mid end-editing callback.
                DispatchQueue.main.async { [weak self] in
                    guard let self, table.row(for: comboBox) == row, rows.indices.contains(row),
                          rows[row].isEmpty else { return }
                    rows.remove(at: row)
                    onChange?(rows)
                }
            } else {
                comboBox.stringValue = rows[row]
            }
            return
        }
        guard rows[row] != name else { return }
        // Edited in place, not through `rows`' observer, so the cell being edited isn't rebuilt.
        isCommittingRow = true
        rows[row] = name
        isCommittingRow = false
        onChange?(rows)
    }

    @objc private func addRow() {
        rows.append("")
        // A row with no net yet is stored as "" (ignored downstream), so it survives reloads.
        onChange?(rows)
        let row = rows.count - 1
        table.scrollRowToVisible(row)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateControls()
        beginEditing(row: row)
    }

    @objc private func removeRow() {
        let selected = table.selectedRow
        guard rows.indices.contains(selected) else { return }
        rows.remove(at: selected)
        onChange?(rows)
    }

    @objc private func editRow() {
        let selected = table.selectedRow
        guard rows.indices.contains(selected) else { return }
        beginEditing(row: selected)
    }

    private func beginEditing(row: Int) {
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        (cell?.subviews.first as? NetNameComboBox)?.beginEditing()
    }
}

/// The bordered, pale-filled box behind NetListEditorView's list, modelled on Xcode's inspector
/// lists (Target Membership).
private final class ListBoxView: NSView {
    // Explicit translucent colours rather than system ones: inside the vibrant glass panel,
    // tertiaryLabelColor/separatorColor resolve to opaque greys meant for vibrancy blending, which
    // land at the same shade as this fill and vanish. Both are lighter than the panel in either
    // appearance (quaternarySystemFill is a black wash in light mode, which reads as darker), with
    // the border clearly stronger than the fill.
    private static let fillColor = dynamicColor(dark: NSColor(white: 1, alpha: 0.1),
                                                light: NSColor(white: 1, alpha: 0.6))
    private static let borderColor = dynamicColor(dark: NSColor(white: 1, alpha: 0.3),
                                                  light: NSColor(white: 0, alpha: 0.2))

    private static func dynamicColor(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Self.fillColor.setFill()
        bounds.fill()
        Self.borderColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
