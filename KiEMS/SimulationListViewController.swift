import Cocoa

/// Which row is currently selected in SimulationListViewController's outline view, passed to
/// onSelectionChanged. Every case carries the index (into document.config.simulations) of the
/// simulation it belongs to, whether it's the simulation's own row or one of its 3 fixed sub-entries.
enum SimulationListSelection: Equatable {
    case simulation(index: Int)
    case geometry(simulationIndex: Int)
    case simulationResults(simulationIndex: Int)
    case fieldViewer(simulationIndex: Int)

    var simulationIndex: Int {
        switch self {
        case .simulation(let index): return index
        case .geometry(let simulationIndex): return simulationIndex
        case .simulationResults(let simulationIndex): return simulationIndex
        case .fieldViewer(let simulationIndex): return simulationIndex
        }
    }
}

/// A simulation row's name field -- just a plain label; all the rename mechanics live on
/// SimulationOutlineView/SimulationListViewController instead of on the field itself. This exists
/// only so SimulationListViewController's NSTextFieldDelegate methods can type-check which fields
/// they're meant to handle without also matching some other, unrelated text field.
private final class SimulationNameField: NSTextField {}

/// Detects a click on a row that's already selected -- the trigger for renaming, Finder-style --
/// which turns out not to be reachable from the cell's own text field at all: a label created via
/// NSTextField(labelWithString:) (isEditable = isSelectable = false) is intentionally hit-test-
/// transparent, exactly so a click anywhere in a row (including over its label) reaches the *row*
/// for normal click-to-select handling rather than being swallowed by the label. That means the
/// label's own mouseDown override never fires; the outline view itself is the right (and only)
/// place to see the click. Overridden here rather than read off outlineView.action/
/// outlineViewSelectionDidChange because both fire *after* AppKit's own row-selection handling has
/// already updated selectedRow -- there'd be no way left to tell "was this row already selected"
/// from "did this click just select it" by the time either of those runs.
private final class SimulationOutlineView: NSOutlineView {
    /// Fired (with the row index) after a plain single click lands on a row that was *already* the
    /// selected row before this click -- never for the click that first selects a row.
    var onClickOnAlreadySelectedRow: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let wasAlreadySelected = event.clickCount == 1 && clickedRow >= 0 && clickedRow == selectedRow
        super.mouseDown(with: event)
        if wasAlreadySelected {
            onClickOnAlreadySelectedRow?(clickedRow)
        }
    }
}

/// One row in SimulationListViewController's outline view -- either a simulation itself (a
/// top-level row) or one of its 3 fixed sub-entries (a child row). Node objects are only rebuilt by
/// reloadData(); refreshRows() reuses the same instances, since NSOutlineView needs stable item
/// identity to preserve expansion state (and, restored explicitly below, selection) across a reload.
private final class SimulationListNode {
    let kind: SimulationListSelection
    var children: [SimulationListNode] = []

    init(kind: SimulationListSelection) {
        self.kind = kind
    }
}

/// Top-level list of every simulation the document will run (EMSConfigBridge.simulations),
/// styled as a frosted-glass source list with +/- buttons at its bottom-right. Each simulation is a
/// top-level outline row with 3 fixed children -- Geometry, Simulation Results, Field Viewer --
/// which DocumentWindowController presents its own (currently-empty) view controller for. Selecting
/// a simulation's own row drives which simulation SimulationPropertiesViewController/
/// SourceListViewController edit -- see DocumentWindowController, which wires this controller's
/// onSelectionChanged into both, and which positions this panel to overlap the header bar above it
/// by `topOverlap`.
final class SimulationListViewController: NSViewController {
    /// How far this panel is positioned to overlap upward into the header bar above it -- a purely
    /// visual effect (the glass material extending under the header's hard edge). Shared with
    /// DocumentWindowController, which uses the same value to place the panel's top anchor.
    static let topOverlap: CGFloat = 20
    /// Clearance below the header's cutoff line so the first row reads clearly below it rather than
    /// sitting flush against it -- topOverlap alone would put row 1 exactly at the boundary.
    private static let contentTopInset: CGFloat = topOverlap + 10

    private weak var document: Document?

    private let outlineView = SimulationOutlineView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    /// Simulations only make sense once a board is actually linked -- add/remove stay disabled
    /// until then (see DocumentWindowController, which calls setProjectAvailable).
    private var isProjectAvailable = false

    /// Rebuilt from document.config.simulations by reloadData(); left untouched by refreshRows() so
    /// item identity (and therefore expansion/selection) survives a cosmetic-only reload.
    private var simulationNodes: [SimulationListNode] = []

    /// Central, per-simulation, per-phase status store -- one PhaseState per (simulation index,
    /// JobKind), covering all 3 sidebar sub-rows (Geometry/.geometryGeneration, Simulation
    /// Results/.simulation, Field Viewer/.fieldPostProcessing). Missing entries read as `.invalid`
    /// (see phaseState(forSimulationIndex:kind:)) -- a simulation that's never been touched, or whose
    /// cache was just invalidated by a config edit, looks the same either way. Driven entirely by
    /// DocumentWindowController's wiring of GeometryViewController/SimulationResultsViewController/
    /// FieldViewerViewController's own callbacks (and, for `.invalid`, its own cache-invalidation call
    /// sites) -- every write here must be tagged with the JobKind it actually belongs to, which is
    /// what keeps one phase's progress from leaking into another row's indicator (the bug this
    /// central store replaces 3 independently-derived dictionaries to fix).
    private var phaseStates: [Int: [JobKind: PhaseState]] = [:]

    /// Fired whenever the selected row changes, including to nil when the list is empty or nothing
    /// is selected.
    var onSelectionChanged: ((SimulationListSelection?) -> Void)?

    /// Fired (with the renamed simulation's index) after a rename performed directly in this list --
    /// SimulationPropertiesViewController's own name field has no other way to notice, the same way
    /// this controller wouldn't notice a rename made there without its own onNameChanged callback.
    var onSimulationRenamed: ((Int) -> Void)?

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        // NSGlassEffectView (macOS 26+'s actual "Liquid Glass" material) -- an earlier headless test
        // run (no attached display/window session in that environment) showed this corrupting the
        // whole window's layout, but that's plausibly an artifact of testing without a real Window
        // Server session rather than a real bug, since Liquid Glass rendering leans on the live
        // display. Its content MUST go through `contentView`, not as a regular subview -- per
        // Apple's docs, arbitrary direct subviews of a glass view aren't guaranteed correct z-order
        // or legibility treatment against the glass. (Confirmed innocent: a bisection investigation
        // into a real window-corruption bug swapped this out as a suspect and the bug persisted --
        // the actual cause was DGCharts, a since-removed third-party charting dependency.)
        let glassView = NSGlassEffectView()
        // Matches the standard macOS window corner radius (no public API reports it -- this is the
        // long-standing value used since the Big Sur redesign) so the bottom-left corner, which sits
        // flush against the window's own bottom-left edge, reads as concentric with it rather than
        // as a second, mismatched curve nested inside the window's. cornerRadius rounds all four
        // corners uniformly (no per-corner control in the public API); the other three aren't
        // against a real window corner, but uniform rounding still reads as an intentional card.
        glassView.cornerRadius = 10
        view = glassView

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(NSLayoutConstraint.Priority.defaultLow, for: .vertical)
        glassView.contentView = content
        // contentView isn't implicitly pinned to fill glassView's bounds -- without this, content
        // (and everything under it) has no constraint tying its size to glassView at all.
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            content.topAnchor.constraint(equalTo: glassView.topAnchor),
            content.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),
        ])

        buildUI(in: content)
        reloadData()
        if !simulationNodes.isEmpty {
            outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        selectionChanged()
    }

    private func buildUI(in content: NSView) {
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Simulation"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.onClickOnAlreadySelectedRow = { [weak self] row in self?.beginRenamingIfSimulationRow(row) }
        // .sourceList style used to imply a chunky row height on its own; now that style is .plain
        // (see below), rowSizeStyle no longer has any real effect on this macOS version (measured:
        // still just 17pt with .large set) -- an explicit rowHeight is the only reliable way left to
        // ask for that same chunky look.
        outlineView.rowHeight = 28
        outlineView.backgroundColor = .clear
        // NOT .sourceList style/selectionHighlightStyle -- either one makes the enclosing
        // NSScrollView insert its own opaque NSVisualEffectView behind the rows (vibrancy meant for
        // a plain window background), which fights the NSGlassEffectView this whole panel sits in.
        // .plain style + the default (.regular) selectionHighlightStyle has no such side effect.
        outlineView.style = .plain
        outlineView.autoresizesOutlineColumn = true

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .circular
        addButton.isBordered = true
        addButton.imagePosition = .imageOnly
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add simulation")
        addButton.target = self
        addButton.action = #selector(addSimulation)
        addButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: 24).isActive = true

        removeButton.bezelStyle = .circular
        removeButton.isBordered = true
        removeButton.imagePosition = .imageOnly
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove simulation")
        removeButton.target = self
        removeButton.action = #selector(removeSimulation)
        removeButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        removeButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        addButton.isEnabled = false
        removeButton.isEnabled = false

        let buttonRow = NSStackView(views: [addButton, removeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(buttonRow)
        // scroll's height is intentionally left undetermined here -- DocumentWindowController pins
        // this whole panel's bottom straight to the window's content view, with no fixed height, so
        // the list always fills whatever vertical space is available as the window resizes.
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.contentTopInset),
            scroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -8),

            // On the right, not the left -- see DocumentWindowController's call site for why.
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    private func rebuildNodes() {
        let count = document?.config.simulations.count ?? 0
        simulationNodes = (0..<count).map { index in
            let node = SimulationListNode(kind: .simulation(index: index))
            node.children = [
                SimulationListNode(kind: .geometry(simulationIndex: index)),
                SimulationListNode(kind: .simulationResults(simulationIndex: index)),
                SimulationListNode(kind: .fieldViewer(simulationIndex: index)),
            ]
            return node
        }
    }

    /// Full rebuild: used whenever the number/order of simulations changes (add/remove). Rebuilds
    /// simulationNodes from scratch, so any previously-held item identity (and therefore selection)
    /// is gone after this -- callers that need to keep something selected must re-select explicitly
    /// afterward using the freshly-rebuilt nodes (see selectSimulationRow(at:) below).
    private func reloadData() {
        rebuildNodes()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        updateButtonEnabledState()
    }

    /// Cosmetic-only reload: used when a property of an existing simulation changes (e.g. its name)
    /// without the set of simulations itself changing. Deliberately does NOT call rebuildNodes() --
    /// reusing the same node objects lets NSOutlineView's reloadData() preserve expansion by item
    /// identity, and the selected row is restored explicitly afterward since, unlike expansion,
    /// NSOutlineView doesn't reliably preserve selection across reloadData() (see includedToggled's
    /// doc comment in SourceListViewController for the same fix, applied there first).
    func refreshRows() {
        let selectedItem = outlineView.item(atRow: outlineView.selectedRow)
        outlineView.reloadData()
        if let selectedItem {
            let row = outlineView.row(forItem: selectedItem)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
    }

    private func updateButtonEnabledState() {
        addButton.isEnabled = isProjectAvailable
        removeButton.isEnabled = isProjectAvailable && outlineView.selectedRow >= 0
    }

    /// Called by DocumentWindowController once a board has been linked (and, symmetrically, would be
    /// called with false if that ever needed to be undone) -- there's nothing meaningful to add a
    /// simulation for before that.
    func setProjectAvailable(_ available: Bool) {
        isProjectAvailable = available
        updateButtonEnabledState()
    }

    /// Called by DocumentWindowController when it adds a simulation on the model directly (e.g. the
    /// default one created on first KiCad project selection), so the list picks it up and selects it
    /// the same way selecting a row here would.
    func simulationAddedExternally(at index: Int) {
        reloadData()
        selectSimulationRow(at: index)
        selectionChanged()
    }

    private func selectSimulationRow(at index: Int) {
        guard let node = simulationNodes.first(where: {
            if case .simulation(let i) = $0.kind { return i == index }
            return false
        }) else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    /// Selects the given entry -- a simulation's own row or one of its 3 fixed sub-entries -- and
    /// fires onSelectionChanged, so the main UI actually shows it. Used by the Jobs window's
    /// double-click-to-jump gesture (DocumentWindowController.selectJob). Expands a sub-entry's
    /// parent simulation row first so the target row is visible to select.
    func select(_ selection: SimulationListSelection) {
        let node: SimulationListNode
        switch selection {
        case .simulation:
            guard let match = simulationNodes.first(where: { $0.kind == selection }) else { return }
            node = match
        case .geometry, .simulationResults, .fieldViewer:
            let index = selection.simulationIndex
            guard let simNode = simulationNodes.first(where: { $0.kind == .simulation(index: index) }),
                  let child = simNode.children.first(where: { $0.kind == selection }) else { return }
            outlineView.expandItem(simNode)
            node = child
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        selectionChanged()
    }

    /// Maps a JobKind to its sub-row's own SimulationListSelection case -- shared by phaseState(...)
    /// and reloadRow(...) so the (simulation node -> child node) lookup logic lives in exactly one
    /// place.
    private static func matchesChild(_ selection: SimulationListSelection, kind: JobKind) -> Bool {
        switch (selection, kind) {
        case (.geometry, .geometryGeneration), (.simulationResults, .simulation),
             (.fieldViewer, .fieldPostProcessing):
            return true
        default:
            return false
        }
    }

    /// Finds and reloads just the sub-row for `index`/`kind`, after phaseStates[index]?[kind] has
    /// already been updated -- shared by every phaseState mutator below so each one stays a one-line
    /// status update. Only reloads the one affected row (unlike includedToggled's full reloadData(),
    /// this state is purely local to a single row, not something that can leave a sibling row's
    /// cached icon stale).
    private func reloadRow(forSimulationIndex index: Int, kind: JobKind) {
        guard let simulationNode = simulationNodes.first(where: {
            if case .simulation(let i) = $0.kind { return i == index }
            return false
        }) else { return }
        guard let childNode = simulationNode.children.first(where: { Self.matchesChild($0.kind, kind: kind) })
        else { return }
        outlineView.reloadItem(childNode)
    }

    /// The current status of one simulation's one phase -- `.invalid` for a phase with no stored
    /// entry (never run, or invalidated since it last ran -- see phaseStates' own doc comment).
    func phaseState(forSimulationIndex index: Int, kind: JobKind) -> PhaseState {
        phaseStates[index]?[kind] ?? .invalid
    }

    private func setPhaseState(_ state: PhaseState, forSimulationIndex index: Int, kind: JobKind) {
        phaseStates[index, default: [:]][kind] = state
        reloadRow(forSimulationIndex: index, kind: kind)
    }

    /// Called by DocumentWindowController whenever a simulation's `kind` phase starts running (from
    /// GeometryViewController.onRunStateChanged for `.geometryGeneration`, or
    /// FieldViewerViewController's own kind-tagged onRunStateChanged for `.fieldPostProcessing` --
    /// see that callback's own doc comment for why it's tagged at all). `.simulation` has no
    /// equivalent eager call: SimulationResultsViewController's own run starting doesn't mean the
    /// Simulation Results *phase* itself has (it computes geometry first, see
    /// EMSPipelineProgressPhase's own doc comment) -- that row only ever enters `.inProgress` once
    /// setProgress(...) actually reports the .simulation phase beginning. Only the `busy == true`
    /// transition is handled here; the matching "finished" transition always arrives via
    /// setCompleted(...) instead, so `busy == false` is a deliberate no-op.
    func setBusy(_ busy: Bool, forSimulationIndex index: Int, kind: JobKind) {
        guard busy else { return }
        setPhaseState(.inProgress(fraction: 0), forSimulationIndex: index, kind: kind)
    }

    /// Called by DocumentWindowController whenever the in-flight pipeline run reports a new fraction
    /// for `kind`'s own phase -- updates that row's circular progress indicator. Unconditional (not
    /// guarded on already being `.inProgress`): every caller only ever forwards a progress report
    /// that arrived while JobScheduler itself considers the underlying job `.running`/`.cancelling`,
    /// so there's no stale-report case to guard against in practice, and `.simulation`'s own row (see
    /// setBusy's own doc comment) relies on this being unconditional to ever enter `.inProgress` at all.
    func setProgress(_ fraction: Double, forSimulationIndex index: Int, kind: JobKind) {
        setPhaseState(.inProgress(fraction: fraction), forSimulationIndex: index, kind: kind)
    }

    /// Called by DocumentWindowController once a simulation's `kind` phase finishes, successfully or
    /// not -- swaps that row's trailing indicator from its circular progress ring to a green filled
    /// "succeeded" dot or a yellow "failed" triangle. The only place a `.inProgress` row ever leaves
    /// that state (see setBusy's own doc comment for why `busy == false` alone doesn't do it).
    func setCompleted(_ success: Bool, forSimulationIndex index: Int, kind: JobKind) {
        setPhaseState(success ? .succeeded : .failed, forSimulationIndex: index, kind: kind)
    }

    /// Marks `kind`'s own phase `.invalid` for `index` -- either because a job JobScheduler reports
    /// as cancelled (as opposed to genuinely failed, which goes through setCompleted(false,...)
    /// instead: the user asked for it to stop, so there's nothing to show as "failed", just nothing
    /// yet), or because a config edit invalidated this phase's cached pipeline stage (see
    /// DocumentWindowController's own cache-invalidation call sites) -- a stale "succeeded" dot must
    /// not keep showing once the cache it was reporting on is gone.
    func setInvalid(forSimulationIndex index: Int, kind: JobKind) {
        setPhaseState(.invalid, forSimulationIndex: index, kind: kind)
    }

    @objc private func selectionChanged() {
        updateButtonEnabledState()
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SimulationListNode else {
            onSelectionChanged?(nil)
            return
        }
        onSelectionChanged?(node.kind)
    }

    /// Re-applies the current row after DocumentWindowController's initial board-loading overlay is
    /// removed. The selection itself exists while loading, but its content is deliberately withheld.
    func notifyCurrentSelection() {
        selectionChanged()
    }

    @objc private func addSimulation() {
        guard let document else { return }
        let count = document.config.simulations.count
        _ = document.config.addSimulationNamed(count == 0 ? "simulation" : "simulation \(count + 1)")
        document.updateChangeCount(.changeDone)
        let newIndex = document.config.simulations.count - 1
        reloadData()
        selectSimulationRow(at: newIndex)
        selectionChanged()
        // The placeholder name just given above is rarely what the user actually wants -- straight
        // into rename mode so they can just start typing over it. Deferred a turn: called
        // synchronously right here, immediately after reloadData()/selectRowIndexes above,
        // editColumn's own first-responder handoff routinely lost to AppKit's own not-yet-finished
        // layout/focus settling for the just-(re)loaded row -- the field would visibly look like it
        // was being edited (isEditable flipped on, text selected) without actually being the key
        // view, so typing went nowhere. Letting this run loop turn finish first avoids that race.
        DispatchQueue.main.async { [weak self] in self?.beginRenaming(forSimulationIndex: newIndex) }
    }

    @objc private func removeSimulation() {
        guard let document else { return }
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SimulationListNode else { return }
        let index = node.kind.simulationIndex
        guard index < document.config.simulations.count else { return }
        document.config.removeSimulation(at: index)
        document.updateChangeCount(.changeDone)
        reloadData()
        selectionChanged()
    }
}

extension SimulationListViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return simulationNodes.count }
        return (item as? SimulationListNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return simulationNodes[index] }
        return (item as! SimulationListNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SimulationListNode)?.children.isEmpty ?? true)
    }
}

extension SimulationListViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let document, let node = item as? SimulationListNode else { return nil }
        switch node.kind {
        case .simulation(let index):
            guard index < document.config.simulations.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("SimulationListCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? makeSimulationCell(identifier: identifier)
            cell.textField?.stringValue = document.config.simulations[index].name
            return cell
        case .geometry(let simulationIndex):
            return Self.makeChildCell(in: outlineView, owner: self, title: "Geometry", symbolName: "cube",
                                       status: phaseState(forSimulationIndex: simulationIndex, kind: .geometryGeneration))
        case .simulationResults(let simulationIndex):
            return Self.makeChildCell(in: outlineView, owner: self, title: "Simulation Results",
                                       symbolName: "chart.bar",
                                       status: phaseState(forSimulationIndex: simulationIndex, kind: .simulation))
        case .fieldViewer(let simulationIndex):
            return Self.makeChildCell(in: outlineView, owner: self, title: "Field Viewer", symbolName: "waveform",
                                       status: phaseState(forSimulationIndex: simulationIndex, kind: .fieldPostProcessing))
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
    }

    private func makeSimulationCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        // A plain label until beginRenaming(atRow:) flips isEditable/isSelectable on -- see
        // SimulationOutlineView for why the click that triggers that has to be detected at the
        // outline view level rather than here on the field itself.
        let textField = SimulationNameField(labelWithString: "")
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Called by SimulationOutlineView.onClickOnAlreadySelectedRow. Ignores the click if `row` turns
    /// out to be one of a simulation's 3 fixed child rows (Geometry/Simulation Results/Field Viewer)
    /// rather than a simulation's own row -- those have no name to rename.
    private func beginRenamingIfSimulationRow(_ row: Int) {
        guard let node = outlineView.item(atRow: row) as? SimulationListNode, case .simulation = node.kind else {
            return
        }
        beginRenaming(atRow: row)
    }

    /// makeIfNecessary: true -- right after addSimulation()'s reloadData(), the new row's cell view
    /// may not have been created yet (NSOutlineView builds row views somewhat lazily), and this is
    /// exactly the case that most needs to work, so silently no-op'ing on a not-yet-existing view
    /// isn't acceptable here the way it might be elsewhere. editColumn(_:row:with:select:) (not a
    /// manual makeFirstResponder(textField) + selectText(nil)) is what actually makes the field both
    /// visibly *and* functionally the key view: called this soon after reloadData()/selectRowIndexes,
    /// a raw makeFirstResponder() call routinely lost a race with AppKit's own not-yet-finished
    /// layout/focus settling for the newly (re)loaded row -- editColumn is NSOutlineView's own
    /// sanctioned API for entering edit mode and doesn't have that problem.
    private func beginRenaming(atRow row: Int) {
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let textField = cell.textField else { return }
        textField.isEditable = true
        textField.isSelectable = true
        outlineView.editColumn(0, row: row, with: nil, select: true)
    }

    /// Called right after a new simulation is added (see addSimulation()) and selected, so the user
    /// can type its real name immediately instead of having to click into the placeholder name
    /// first.
    private func beginRenaming(forSimulationIndex index: Int) {
        guard let node = simulationNodes.first(where: {
            if case .simulation(let i) = $0.kind { return i == index }
            return false
        }) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        beginRenaming(atRow: row)
    }

    private func endRenaming(_ textField: NSTextField, committing: Bool) {
        let row = outlineView.row(for: textField)
        if row >= 0, let node = outlineView.item(atRow: row) as? SimulationListNode,
           case .simulation(let index) = node.kind, let document, index < document.config.simulations.count {
            if committing {
                let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty {
                    document.config.simulations[index].name = newName
                    document.updateChangeCount(.changeDone)
                    onSimulationRenamed?(index)
                }
            }
            // Reads back from the model rather than trusting textField.stringValue as-is -- covers
            // both a cancelled edit (revert) and an empty/whitespace-only commit attempt (silently
            // ignored above, so the field must be put back to the name that's actually still in
            // effect rather than left showing the rejected blank text).
            textField.stringValue = document.config.simulations[index].name
        }
        textField.isEditable = false
        textField.isSelectable = false
    }

    private static let spinnerIdentifier = NSUserInterfaceItemIdentifier("SimulationListChildCell.spinner")
    private static let statusImageIdentifier = NSUserInterfaceItemIdentifier("SimulationListChildCell.statusImage")

    /// Invalid/succeeded/failed glyphs for makeChildCell's trailing status indicator -- template
    /// images so contentTintColor (set fresh per state in makeChildCell) actually colors them, built
    /// once and reused across every cell/state.
    private static let invalidImage: NSImage = {
        let image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Not yet run")!
        image.isTemplate = true
        return image
    }()
    private static let succeededImage: NSImage = {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Succeeded")!
        image.isTemplate = true
        return image
    }()
    private static let failedImage: NSImage = {
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Failed")!
        image.isTemplate = true
        return image
    }()

    /// Sub-entry rows (Geometry/Simulation Results/Field Viewer) are identical in every simulation,
    /// so a distinct reuse identifier per symbol (rather than per node) is enough to recycle them.
    /// `status` drives the row's trailing indicator: a determinate circular progress ring while
    /// `.inProgress`, otherwise a small tinted status glyph (blue outline "invalid", green filled
    /// "succeeded", yellow triangle "failed") -- every child row gets one, including Field Viewer.
    /// Both indicator subviews are built once and reused alongside the rest of the cell, just
    /// re-valued/re-toggled fresh on every call.
    private static func makeChildCell(
        in outlineView: NSOutlineView, owner: Any?, title: String, symbolName: String, status: PhaseState
    ) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("SimulationListChildCell-\(symbolName)")
        let cell: NSTableCellView
        let imageView: NSImageView
        let spinner: NSProgressIndicator
        let statusImageView: NSImageView
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: owner) as? NSTableCellView,
           let reusedImageView = reused.imageView,
           let reusedSpinner = reused.subviews.first(where: { $0.identifier == spinnerIdentifier }) as? NSProgressIndicator,
           let reusedStatusImageView = reused.subviews.first(where: { $0.identifier == statusImageIdentifier }) as? NSImageView {
            cell = reused
            imageView = reusedImageView
            spinner = reusedSpinner
            statusImageView = reusedStatusImageView
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            imageView = NSImageView()
            imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            imageView.contentTintColor = .secondaryLabelColor
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let textField = NSTextField(labelWithString: title)
            textField.textColor = .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false

            spinner = NSProgressIndicator()
            spinner.identifier = spinnerIdentifier
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.isIndeterminate = false
            spinner.minValue = 0
            spinner.maxValue = 1
            spinner.translatesAutoresizingMaskIntoConstraints = false

            statusImageView = NSImageView()
            statusImageView.identifier = statusImageIdentifier
            statusImageView.translatesAutoresizingMaskIntoConstraints = false
            // A slight drop shadow to lift the status dot/triangle off the row background --
            // layer-backing is required for CALayer's own shadow* properties to take effect.
            statusImageView.wantsLayer = true
            statusImageView.layer?.shadowColor = NSColor.black.cgColor
            statusImageView.layer?.shadowOpacity = 0.5
            statusImageView.layer?.shadowRadius = 1
            statusImageView.layer?.shadowOffset = CGSize(width: 0, height: -1)

            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.addSubview(spinner)
            cell.addSubview(statusImageView)
            cell.textField = textField
            cell.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),

                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                spinner.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                spinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: 14),
                spinner.heightAnchor.constraint(equalToConstant: 14),

                statusImageView.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                statusImageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                statusImageView.widthAnchor.constraint(equalToConstant: 14),
                statusImageView.heightAnchor.constraint(equalToConstant: 14),
            ])
        }

        cell.textField?.stringValue = title
        // At most one of the two trailing indicators is ever visible at once -- they share the same
        // slot at the row's trailing edge, well clear of the leading-edge icon.
        switch status {
        case .inProgress(let fraction):
            spinner.isHidden = false
            spinner.doubleValue = fraction
            statusImageView.isHidden = true
        case .invalid:
            spinner.isHidden = true
            statusImageView.isHidden = false
            statusImageView.image = Self.invalidImage
            statusImageView.contentTintColor = .systemBlue
        case .succeeded:
            spinner.isHidden = true
            statusImageView.isHidden = false
            statusImageView.image = Self.succeededImage
            statusImageView.contentTintColor = .systemGreen
        case .failed:
            spinner.isHidden = true
            statusImageView.isHidden = false
            statusImageView.image = Self.failedImage
            statusImageView.contentTintColor = .systemYellow
        }
        return cell
    }
}

extension SimulationListViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? SimulationNameField else { return }
        endRenaming(textField, committing: true)
    }

    /// Escape cancels the rename (reverting to the simulation's actual current name) instead of
    /// AppKit's default handling, which would otherwise leave the field mid-edit with unsaved text
    /// and no clear way out via the keyboard.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let textField = control as? SimulationNameField
        else { return false }
        endRenaming(textField, committing: false)
        outlineView.window?.makeFirstResponder(outlineView)
        return true
    }
}
