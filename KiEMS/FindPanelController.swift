import AppKit

/// One thing the Find panel can select on the board.
struct BoardFindResult: Equatable {
    enum Kind: Equatable {
        case net(String)
        case component(reference: String, value: String)
        case pin(BoardPinRef, function: String)
    }

    let kind: Kind

    var title: String {
        switch kind {
        case let .net(name): return name
        case let .component(reference, _): return reference
        case let .pin(pin, function):
            let name = BoardPinDisplay.name(function: function, number: pin.number)
            return "\(pin.reference)/\(name)(\(pin.number))"
        }
    }

    var detail: String {
        switch kind {
        case .net: return "Net"
        case let .component(_, value): return value.isEmpty ? "Component" : "Component · \(value)"
        case let .pin(pin, function):
            let net = (pin.net ?? "").isEmpty ? "unconnected" : pin.net!
            return function.isEmpty ? "Pin · \(net)" : "Pin \(function) · \(net)"
        }
    }

    var target: BoardPickTarget {
        switch kind {
        case let .net(name): return .net(name)
        case let .component(reference, _): return .component(reference)
        case let .pin(pin, _): return .pin(reference: pin.reference, number: pin.number, net: pin.net)
        }
    }
}

/// Matches Find panel queries against the board's nets, components and pins. A query naming a
/// component and pin -- "U1/3", "U1.3", "U1:3", "U1 3" or "U1 pin 3" -- finds that pin
/// (by pin number or pin function), "U1/" alone lists all of U1's pins, and "U1-GND" finds U1's
/// pins connected to GND; anything else matches net names, references and values.
struct BoardFindIndex {
    let nets: [String]
    let footprints: [KicadFootprintInfo]

    private static let resultLimit = 500

    func results(for rawQuery: String) -> [BoardFindResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var exact: [BoardFindResult] = []
        var prefix: [BoardFindResult] = []
        var contains: [BoardFindResult] = []
        func add(_ result: BoardFindResult, rank: Int) {
            switch rank {
            case 0: exact.append(result)
            case 1: prefix.append(result)
            default: contains.append(result)
            }
        }

        if let (reference, netQuery) = Self.splitPinNetQuery(query),
           footprints.contains(where: { $0.reference.caseInsensitiveCompare(reference) == .orderedSame }) {
            for footprint in footprints where Self.rank(footprint.reference, reference) == 0 {
                for pin in footprint.pins {
                    // A bare "U1-" lists every pin on U1.
                    guard let rank = netQuery.isEmpty ? 1 : Self.netRank(pin.netName, netQuery) else { continue }
                    add(Self.pinResult(footprint, pin), rank: rank)
                }
            }
        } else if let (reference, pinQuery) = Self.splitPinQuery(query) {
            for footprint in footprints where Self.rank(footprint.reference, reference) == 0 {
                for pin in footprint.pins {
                    // A bare "U1/" lists every pin on U1.
                    if pinQuery.isEmpty { add(Self.pinResult(footprint, pin), rank: 1); continue }
                    let rank = min(Self.rank(pin.number, pinQuery) ?? 3, (Self.rank(pin.function, pinQuery) ?? 3) + 1)
                    guard rank < 3 else { continue }
                    add(Self.pinResult(footprint, pin), rank: rank)
                }
            }
        }

        for net in nets where !net.isEmpty {
            if let rank = Self.netRank(net, query) {
                add(BoardFindResult(kind: .net(net)), rank: rank)
            }
        }
        for footprint in footprints {
            let referenceRank = Self.rank(footprint.reference, query)
            let valueRank = Self.rank(footprint.value, query).map { max($0, 1) + 1 }
            if let rank = [referenceRank, valueRank].compactMap({ $0 }).min() {
                add(BoardFindResult(kind: .component(reference: footprint.reference, value: footprint.value)),
                    rank: min(rank, 2))
            }
        }

        let ordered = exact + prefix.sorted(by: Self.displayOrder) + contains.sorted(by: Self.displayOrder)
        return Array(ordered.prefix(Self.resultLimit))
    }

    private static func pinResult(_ footprint: KicadFootprintInfo, _ pin: KicadFootprintPin) -> BoardFindResult {
        BoardFindResult(kind: .pin(BoardPinRef(reference: footprint.reference, number: pin.number, net: pin.netName),
                                   function: pin.function))
    }

    /// rank(_:_:) against a net's full name or its leaf: KiCad prefixes hierarchical net names
    /// with their sheet path, and "/SDA" should be found by "SDA" as readily as an exact match.
    private static func netRank(_ net: String, _ query: String) -> Int? {
        let leaf = net.split(separator: "/").last.map(String.init) ?? net
        return [rank(net, query), rank(leaf, query)].compactMap { $0 }.min()
    }

    /// Splits "U1-GND" (spaces round the dash optional) into a reference and a net, or nil if the
    /// query isn't one. Splits at the first dash, as net names often contain dashes themselves.
    private static func splitPinNetQuery(_ query: String) -> (String, String)? {
        guard let dash = query.firstIndex(of: "-") else { return nil }
        let reference = query[..<dash].trimmingCharacters(in: .whitespaces)
        let net = query[query.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        return reference.isEmpty ? nil : (reference, net)
    }

    /// 0 for an exact (case-insensitive) match, 1 for a prefix, 2 for a substring, nil otherwise.
    private static func rank(_ candidate: String, _ query: String) -> Int? {
        guard !candidate.isEmpty else { return nil }
        if candidate.caseInsensitiveCompare(query) == .orderedSame { return 0 }
        guard let range = candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        return range.lowerBound == candidate.startIndex ? 1 : 2
    }

    private static func displayOrder(_ a: BoardFindResult, _ b: BoardFindResult) -> Bool {
        a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    /// Splits "U1/3"-style queries into a reference and a pin, or nil if the query isn't one.
    private static func splitPinQuery(_ query: String) -> (String, String)? {
        let words = query.split(whereSeparator: { $0 == " " }).map(String.init)
        if words.count == 3, words[1].caseInsensitiveCompare("pin") == .orderedSame { return (words[0], words[2]) }
        if words.count == 2 { return (words[0], words[1]) }
        for separator in ["/", ".", ":"] {
            let parts = query.components(separatedBy: separator)
            if parts.count == 2, !parts[0].isEmpty { return (parts[0], parts[1]) }
        }
        return nil
    }
}

/// A floating Find panel for one document window: type a net name, component reference, or
/// reference/pin ("U1/3"), and pick a match to select it on the board. Return selects the
/// highlighted match; "Select All" selects every match as one group.
final class FindPanelController: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var index = BoardFindIndex(nets: [], footprints: []) {
        didSet { refreshResults() }
    }
    var onSelect: (([BoardFindResult]) -> Void)?

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let selectAllButton = NSButton(title: "Select All", target: nil, action: nil)
    private var results: [BoardFindResult] = []

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = "Find"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.minSize = NSSize(width: 260, height: 200)
        super.init(window: panel)
        buildContent(in: panel)
        // Restores the frame the user last left the panel at (shared by every document's panel).
        hasSavedFrame = panel.setFrameUsingName(Self.frameAutosaveName)
        panel.setFrameAutosaveName(Self.frameAutosaveName)
    }

    /// The document window the panel searches; actions the panel can't handle (Save, Undo, …) go to it.
    private weak var parentWindow: NSWindow?

    /// Routes menu actions and their shortcuts the panel doesn't handle through the document
    /// window's responder chain, so they behave as if that window were key.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        guard let parent = parentWindow else { return super.supplementalTarget(forAction: action, sender: sender) }
        var responder: NSResponder? = parent.firstResponder
        while let r = responder {
            if r.responds(to: action) { return r }
            responder = r.nextResponder
        }
        for candidate in [parent.delegate as AnyObject?, parent.windowController, parent.windowController?.document] {
            if let candidate, candidate !== self, candidate.responds(to: action) { return candidate }
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    private static let frameAutosaveName = "KiEMSFindPanel"
    /// True once the panel has a user-chosen frame, so `show` stops placing it beside the parent.
    private var hasSavedFrame = false

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent(in panel: NSPanel) {
        searchField.placeholderString = "Net, reference, or reference/pin"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.style = .inset
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllMatches)
        selectAllButton.controlSize = .small
        selectAllButton.bezelStyle = .rounded

        let footer = NSStackView(views: [statusLabel, selectAllButton])
        footer.orientation = .horizontal
        let stack = NSStackView(views: [searchField, scrollView, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for view in [searchField, scrollView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        panel.contentView = stack
        refreshResults()
    }

    /// Shows the panel beside `parent` and focuses the search field with its text selected.
    func show(relativeTo parent: NSWindow?) {
        guard let panel = window else { return }
        parentWindow = parent
        if !panel.isVisible, !hasSavedFrame, let parent {
            let frame = parent.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 20, y: frame.maxY - 60))
            hasSavedFrame = true
        }
        showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    @objc private func searchChanged() {
        refreshResults()
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshResults()
    }

    /// Arrow keys move through the matches without leaving the search field; Return selects.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let current = tableView.selectedRow
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = current < 0 ? 0 : min(max(current + delta, 0), results.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            selectHighlighted()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty { window?.close() } else { searchField.stringValue = ""; refreshResults() }
            return true
        default:
            return false
        }
    }

    private func refreshResults() {
        results = index.results(for: searchField.stringValue)
        tableView.reloadData()
        if !results.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        selectAllButton.isEnabled = results.count > 1
        switch (searchField.stringValue.isEmpty, results.count) {
        case (true, _): statusLabel.stringValue = "\(index.nets.count) nets, \(index.footprints.count) components"
        case (false, 0): statusLabel.stringValue = "No matches"
        case (false, 1): statusLabel.stringValue = "1 match"
        case (false, let count): statusLabel.stringValue = "\(count) matches"
        }
    }

    private func selectHighlighted() {
        let rows = tableView.selectedRowIndexes.filter { results.indices.contains($0) }
        let chosen = rows.isEmpty ? Array(results.prefix(1)) : rows.map { results[$0] }
        guard !chosen.isEmpty else { NSSound.beep(); return }
        onSelect?(chosen)
    }

    @objc private func rowClicked() {
        guard tableView.clickedRow >= 0 else { return }
        selectHighlighted()
    }

    @objc private func selectAllMatches() {
        guard !results.isEmpty else { return }
        onSelect?(results)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FindResultCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let title = NSTextField(labelWithString: "")
            title.lineBreakMode = .byTruncatingMiddle
            let detail = NSTextField(labelWithString: "")
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [title, detail])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = title
            return cell
        }()
        let result = results[row]
        cell.textField?.stringValue = result.title
        (cell.textField?.superview as? NSStackView)?.arrangedSubviews.last.flatMap { $0 as? NSTextField }?
            .stringValue = result.detail
        return cell
    }
}
