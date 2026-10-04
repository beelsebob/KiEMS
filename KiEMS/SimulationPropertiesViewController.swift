import Cocoa

/// The "simulation-wide properties" panel: name, ground net, frequency range, via
/// settings. Edits whichever simulation SimulationListViewController has selected (see
/// setSelectedSimulationIndex) -- viaPlatingThickness/viaFillingEpsilon/frequencyStart/frequencyStop
/// stay editable regardless (they're document-level, not per-simulation), but the rest disable
/// themselves when nothing is selected.
final class SimulationPropertiesViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate {
    private static let formFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private weak var document: Document?
    private var selectedIndex: Int?

    /// Fired whenever the selected simulation's name changes (see nameChanged) --
    /// DocumentWindowController wires this to SimulationListViewController.refreshRows(), which has
    /// no other way to learn that the row it's showing for this simulation is now stale.
    var onNameChanged: (() -> Void)?

    /// Fired (with the changed simulation's index) whenever a field that affects the *shape* of the
    /// geometry step's output changes -- via edge distance/spacing or the ground net
    /// itself. DocumentWindowController wires this to GeometryViewController.invalidateCache(
    /// forSimulationIndex:), so a stale cached geometry/error from before the edit doesn't keep
    /// being shown. Deliberately not fired for platingThickness/fillingEpsilon/frequency fields --
    /// those affect the FDTD run itself, not the geometry step's own output.
    var onGeometryParametersChanged: ((Int) -> Void)?

    /// Fired whenever maxStepsField changes -- unlike onGeometryParametersChanged, this doesn't
    /// affect geometry at all (it's a pure FDTD-run setting, document-level like frequency/via
    /// plating above it), so it only needs to invalidate simulation *results*, and for every
    /// simulation in the document at once (maxSteps isn't per-simulation). Too low a value truncates
    /// the FDTD run before its energy has decayed, which is exactly the bug this field exists to let
    /// the user fix -- so a stale cached result from before raising it would defeat the point.
    var onFDTDParametersChanged: (() -> Void)?
    var onResultsParametersChanged: ((Int) -> Void)?
    /// Called when the Differential Pair checkbox is ticked, so nets/pins/excitations added before
    /// it was ticked get the same partner mirroring WholeBoardViewController applies to ones added
    /// after -- see WholeBoardViewController.reconcileDifferentialPairs(in:). Only that controller
    /// has the board's footprint/pin data needed to find partner pins.
    var onDifferentialPairEnabled: ((EMSSimulationBridge) -> Void)?

    // Gates SimulationConfig::isDifferentialPair() -- see its own doc comment for exactly what
    // that changes (whether reciprocal net-pair metadata actually gets turned into a diffPairs()
    // entry, or the simulation stays plain single-ended regardless of any such metadata).
    private let differentialPairCheckbox = NSButton(checkboxWithTitle: "Differential Pair", target: nil, action: nil)
    private let nameField = NSTextField(string: "")
    // NetNameComboBox rather than NSComboBox so net names render with their KiCad markup
    // (overlines included) in the field and its menu -- see NetNameComboBox.
    private let groundNameComboBox = NetNameComboBox()
    // kiems::SimulationConfig::edgeTerminatedNets(): one row per net, each picked with a combo box.
    private let edgeTerminationTable = NSTableView()
    private let edgeTerminationScroll = NSScrollView()
    private let addEdgeTerminationButton = NSButton()
    private let removeEdgeTerminationButton = NSButton()
    private var edgeTerminatedNetRows: [String] = []
    private let maxStepsField = NSTextField(string: "")
    // The FDTD grid's own base target cell size -- document-level (EMSConfig), not per-simulation,
    // same as maxStepsField beside it. maxTimestepValueLabel/simulationRealTimeValueLabel are
    // read-only, derived from this and maxStepsField together (see updateDerivedTimingLabels()) --
    // each paired with its own caption via labeled(), the same way gridDensityField/maxStepsField
    // are, so the two rows' columns line up (see gridAndStepsRow/derivedTimingRow below).
    private let gridDensityField = NSTextField(string: "")
    // The absorbing boundary's depth in cells on every face -- document-level like gridDensityField, and
    // like it changes every simulation's geometry (the grid gains that many cells on each side).
    private let absorbingBoundaryField = NSTextField(string: "")
    private let maxTimestepValueLabel = NSTextField(labelWithString: "")
    private let simulationRealTimeValueLabel = NSTextField(labelWithString: "")
    private let viaEdgeDistanceField = NSTextField(string: "")
    private let viaSpacingField = NSTextField(string: "")
    private let platingThicknessField = NSTextField(string: "")
    private let fillingEpsilonField = NSTextField(string: "")
    // The FDTD frequency sweep range -- document-level (EMSConfig), not per-simulation, same as
    // platingThicknessField/fillingEpsilonField, so these stay enabled/populated regardless of
    // whether a simulation is selected (see reload()/setPerSimulationFieldsEnabled()).
    private let frequencyStartField = NSTextField(string: "")
    private let frequencyStopField = NSTextField(string: "")
    private let eyeBitRateField = NSTextField(string: "")

    // Length fields each get their own formatter instance -- the displayed/accepted unit is
    // per-instance state (see MicrometerValueFormatter), so sharing one across fields would make
    // them all switch units together whenever any single field's unit changed.
    private let gridDensityFormatter = MicrometerValueFormatter()
    private let viaEdgeDistanceFormatter = MicrometerValueFormatter()
    private let viaSpacingFormatter = MicrometerValueFormatter()
    private let platingThicknessFormatter = MicrometerValueFormatter()
    private let frequencyStartFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    private let frequencyStopFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    private let eyeBitRateFormatter = UnitSuffixValueFormatter(
        displaySuffix: "bit/s", acceptedSuffixes: ["bit/s", "bps"],
        scaledSuffixes: SIPrefix.allCases.flatMap { prefix in
            prefix.inputSymbols.flatMap { symbol in
                [
                    (suffix: "\(symbol)b/s", factor: prefix.factor),
                    (suffix: "\(symbol)B/s", factor: 8 * prefix.factor),
                ]
            }
        },
        autoSelectsSIPrefix: true)
    private let maxStepsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0 // Timesteps are a plain integer count, never fractional.
        return formatter
    }()

    private let absorbingBoundaryFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 1
        formatter.maximum = 64
        return formatter
    }()

    private var groundNetClassNames: [String] = []
    private var groundNetNames: [String] = []


    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        buildUI()
        reload()
    }

    // At the small system font, "Frequency Range:" is just under 95pt wide. Matching the column to
    // that width lets the sidebar's own inset provide the requested leading padding rather than
    // adding another inset inside the right-aligned label column.
    private static let labelWidth: CGFloat = 95

    private func labeled(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = Self.formFont
        label.textColor = .labelColor
        label.alignment = .right
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func section(_ title: String, views: [NSView]) -> NSStackView {
        let separator = NSBox()
        separator.boxType = .separator
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let section = NSStackView(views: [separator, heading] + views)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        section.setCustomSpacing(8, after: separator)
        section.setCustomSpacing(10, after: heading)
        separator.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        for view in views {
            view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    private func buildUI() {
        differentialPairCheckbox.target = self
        differentialPairCheckbox.action = #selector(differentialPairToggled)
        differentialPairCheckbox.controlSize = .small
        differentialPairCheckbox.font = Self.formFont

        nameField.target = self
        nameField.action = #selector(nameChanged)

        groundNameComboBox.onCommit = { [weak self] name, tag in self?.groundNameChanged(name, tag: tag) }
        groundNameComboBox.controlSize = .small
        groundNameComboBox.font = Self.formFont

        viaEdgeDistanceField.formatter = viaEdgeDistanceFormatter
        viaSpacingField.formatter = viaSpacingFormatter
        platingThicknessField.formatter = platingThicknessFormatter
        fillingEpsilonField.formatter = Self.plainNumberFormatter
        frequencyStartField.formatter = frequencyStartFormatter
        frequencyStopField.formatter = frequencyStopFormatter
        eyeBitRateField.formatter = eyeBitRateFormatter
        maxStepsField.formatter = maxStepsFormatter
        gridDensityField.formatter = gridDensityFormatter
        absorbingBoundaryField.formatter = absorbingBoundaryFormatter

        for field in [viaEdgeDistanceField, viaSpacingField, platingThicknessField,
                      fillingEpsilonField, frequencyStartField, frequencyStopField, maxStepsField,
                      gridDensityField, absorbingBoundaryField, eyeBitRateField] {
            field.controlSize = .small
            field.font = Self.formFont
            field.alignment = .right
            field.target = self
            field.action = #selector(numberFieldChanged(_:))
        }

        maxTimestepValueLabel.textColor = .secondaryLabelColor
        simulationRealTimeValueLabel.textColor = .secondaryLabelColor
        for field in [nameField, maxTimestepValueLabel, simulationRealTimeValueLabel] {
            field.controlSize = .small
            field.font = Self.formFont
        }
        maxTimestepValueLabel.alignment = .right
        simulationRealTimeValueLabel.alignment = .right

        let rangeSeparator = NSTextField(labelWithString: "–")
        rangeSeparator.font = Self.formFont
        rangeSeparator.textColor = .secondaryLabelColor
        let frequencyRange = NSStackView(views: [frequencyStartField, rangeSeparator, frequencyStopField])
        frequencyRange.orientation = .horizontal
        frequencyRange.alignment = .centerY
        frequencyRange.distribution = .fill
        frequencyRange.spacing = 3
        frequencyStartField.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        frequencyStopField.widthAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        frequencyStartField.widthAnchor.constraint(equalTo: frequencyStopField.widthAnchor).isActive = true
        rangeSeparator.setContentHuggingPriority(.required, for: .horizontal)

        let nameRow = labeled("Name:", nameField)
        let networksSection = section("Networks", views: [
                labeled("", differentialPairCheckbox),
                labeled("Ground Net:", groundNameComboBox),
                labeled("Edge Terminated Nets:", buildEdgeTerminationTable()),
            ])
        let geometrySection = section("Geometry", views: [
                labeled("Stitching Inset:", viaEdgeDistanceField),
                labeled("Stitching Spacing:", viaSpacingField),
                labeled("Via Plating Thickness:", platingThicknessField),
                labeled("Via Filling Epsilon:", fillingEpsilonField),
            ])
        let resolutionSection = section("Resolution", views: [
                labeled("Min Resolution:", gridDensityField),
                labeled("Absorbing Boundary (cells):", absorbingBoundaryField),
                labeled("Timestep Length:", maxTimestepValueLabel),
                labeled("Max Timesteps:", maxStepsField),
                labeled("Sim Real Time:", simulationRealTimeValueLabel),
                labeled("Frequency Range:", frequencyRange),
                labeled("Digital Bitrate:", eyeBitRateField),
            ])
        let topLevelViews = [nameRow, networksSection, geometrySection, resolutionSection]
        let stack = NSStackView(views: topLevelViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in topLevelViews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        view.addSubview(stack)
        // Pinned to all four edges, not just leading/top -- view (a plain NSView with no intrinsic
        // content size of its own) needs its size fully determined by stack's, or it collapses to
        // zero when arranged as a subview inside WholeBoardViewController's info column.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    private func buildEdgeTerminationTable() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("net"))
        column.resizingMask = .autoresizingMask
        edgeTerminationTable.addTableColumn(column)
        edgeTerminationTable.headerView = nil
        edgeTerminationTable.rowHeight = 22
        edgeTerminationTable.intercellSpacing = NSSize(width: 0, height: 2)
        edgeTerminationTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        edgeTerminationTable.usesAlternatingRowBackgroundColors = true
        edgeTerminationTable.dataSource = self
        edgeTerminationTable.delegate = self

        edgeTerminationScroll.documentView = edgeTerminationTable
        edgeTerminationScroll.hasVerticalScroller = true
        edgeTerminationScroll.autohidesScrollers = true
        edgeTerminationScroll.borderType = .bezelBorder
        edgeTerminationScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true

        for (button, symbol, description, action) in [
            (addEdgeTerminationButton, "plus", "Add edge-terminated net", #selector(addEdgeTerminatedNet)),
            (removeEdgeTerminationButton, "minus", "Remove edge-terminated net", #selector(removeEdgeTerminatedNet)),
        ] {
            button.bezelStyle = .circular
            button.isBordered = true
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            button.controlSize = .small
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        let buttonRow = NSStackView(views: [addEdgeTerminationButton, removeEdgeTerminationButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 4

        let container = NSStackView(views: [edgeTerminationScroll, buttonRow])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        edgeTerminationScroll.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private static let plainNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    private var selectedSimulation: EMSSimulationBridge? {
        guard let document, let selectedIndex else { return nil }
        let simulations = document.config.simulations
        guard selectedIndex >= 0, selectedIndex < simulations.count else { return nil }
        return simulations[selectedIndex]
    }

    /// Called by SimulationListViewController (via DocumentWindowController) whenever the selected
    /// simulation changes, including to nil when nothing (or the list is empty).
    func setSelectedSimulationIndex(_ index: Int?) {
        selectedIndex = index
        reload()
    }

    /// Called after another view (the board's context menu) changes this simulation's ground net or
    /// edge-terminated nets directly: re-shows those fields and invalidates its geometry, exactly
    /// as an edit made here would.
    func simulationEditedElsewhere() {
        reload()
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
    }

    /// Called by SimulationListViewController (via DocumentWindowController) after a rename
    /// performed directly in the source list -- if this panel happens to be showing that same
    /// simulation right now, its own name field would otherwise go stale. Deliberately just the one
    /// field, not a full setSelectedSimulationIndex(_:) re-call: that also re-queries net lists,
    /// which a plain rename should not disturb.
    func refreshNameFieldIfSelected(index: Int) {
        guard selectedIndex == index, let sim = selectedSimulation else { return }
        nameField.stringValue = sim.name
    }

    private func reload() {
        guard let document else { return }
        platingThicknessField.doubleValue = document.config.viaPlatingThickness
        fillingEpsilonField.doubleValue = document.config.viaFillingEpsilon
        frequencyStartField.doubleValue = document.config.frequencyStart
        frequencyStopField.doubleValue = document.config.frequencyStop
        maxStepsField.integerValue = document.config.maxSteps
        gridDensityField.doubleValue = document.config.gridDensity
        absorbingBoundaryField.integerValue = document.config.absorbingBoundaryCells
        updateDerivedTimingLabels()

        guard let sim = selectedSimulation else {
            nameField.stringValue = ""
            viaEdgeDistanceField.stringValue = ""
            viaSpacingField.stringValue = ""
            eyeBitRateField.stringValue = ""
            differentialPairCheckbox.state = .off
            groundNameComboBox.entries = []
            groundNameComboBox.stringValue = ""
            edgeTerminatedNetRows = []
            edgeTerminationTable.reloadData()
            setPerSimulationFieldsEnabled(false)
            return
        }
        setPerSimulationFieldsEnabled(true)

        nameField.stringValue = sim.name
        differentialPairCheckbox.state = sim.isDifferentialPair ? .on : .off
        viaEdgeDistanceField.doubleValue = sim.viaEdgeDistance
        viaSpacingField.doubleValue = sim.viaSpacing
        eyeBitRateField.doubleValue = sim.eyeBitRate
        edgeTerminatedNetRows = sim.edgeTerminatedNets
        edgeTerminationTable.reloadData()

        refreshNetLists()

        // A brand-new simulation (added via SimulationListViewController's + button, as opposed to
        // the board's first, auto-created one -- see DocumentWindowController.importSucceeded, which
        // already guesses for that case) has no real ground net choice yet -- EMSConfigBridge's
        // addSimulationNamed: sets it to an empty string, not nil (to_json() dereferences the active
        // kind's optional unconditionally, so it can never be left unset -- see that method's own
        // comment), so isEmpty is the right check here, not == nil. Left alone,
        // updateGroundNameComboBox() below has nothing to select() for an empty name, so the field
        // shows whichever net query happened to return first -- which reads as a deliberate but
        // wrong guess ("/MCU/DS1/En" instead of the obviously-better "GND"), when really nothing was
        // ever guessed at all. groundNetNames reflects the last completed refreshNetLists() (a board
        // linked earlier this session, same as every other simulation's ground-net choices draw
        // from), not this call's own in-flight one, so this is already current rather than needing
        // to wait on it.
        if sim.groundNetName?.isEmpty ?? true {
            let names = sim.groundNetKind == .net ? groundNetNames : groundNetClassNames
            applyGroundSelection(GroundNetHeuristic.bestGuess(among: names), to: sim)
        }
    }

    private func setPerSimulationFieldsEnabled(_ enabled: Bool) {
        for control in [nameField, differentialPairCheckbox, groundNameComboBox,
                         viaEdgeDistanceField, viaSpacingField, eyeBitRateField, edgeTerminationTable,
                         addEdgeTerminationButton, removeEdgeTerminationButton] as [NSControl] {
            control.isEnabled = enabled
        }
    }

    /// Called after a KiCad board is linked (see DocumentWindowController) -- the ground-net
    /// popup's choices depend on the board that was just linked.
    func refreshNetLists() {
        guard let document, let board = document.board else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let classes = (try? board.netClasses()) ?? []
            let nets = (try? board.allNets()) ?? []
            DispatchQueue.main.async {
                self?.groundNetClassNames = NetNameFormatting.sortedForDisplay(classes)
                self?.groundNetNames = NetNameFormatting.sortedForDisplay(nets)
                self?.updateGroundNameComboBox()
                self?.edgeTerminationTable.reloadData()
            }
        }
    }

    private func updateGroundNameComboBox() {
        guard let sim = selectedSimulation else { return }
        groundNameComboBox.entries = [.heading("Nets")]
            + groundNetNames.map { .name($0, tag: EMSGroundSelectorKind.net.rawValue) }
            + [.separator, .heading("Net Classes")]
            + groundNetClassNames.map { .name($0, tag: EMSGroundSelectorKind.netClass.rawValue) }
        groundNameComboBox.stringValue = sim.groundNetName ?? ""
    }

    @objc private func nameChanged() {
        selectedSimulation?.name = nameField.stringValue
        document?.updateChangeCount(.changeDone)
        onNameChanged?()
    }

    /// See SimulationConfig::isDifferentialPair()'s own doc comment -- treated the same as a
    /// ground-net/hull-padding edit (onGeometryParametersChanged, not a dedicated callback): it
    /// doesn't itself move any port, but it does change what resolveSimulationPorts() populates
    /// diffPairs() with, which downstream Results/Field Viewer state depends on, so any cache from
    /// before the edit is just as stale.
    @objc private func differentialPairToggled() {
        guard let sim = selectedSimulation else { return }
        sim.isDifferentialPair = differentialPairCheckbox.state == .on
        if sim.isDifferentialPair {
            onDifferentialPairEnabled?(sim)
        }
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
    }

    private func applyGroundSelection(_ name: String?, to sim: EMSSimulationBridge) {
        sim.groundNetName = name
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
        updateGroundNameComboBox()
    }

    /// `tag` is the picked menu entry's EMSGroundSelectorKind, or nil for typed text -- which is
    /// accepted only if it names a real net or net class; anything else reverts the field.
    private func groundNameChanged(_ name: String, tag: Int?) {
        guard let sim = selectedSimulation else { return }
        var kind = tag.flatMap { EMSGroundSelectorKind(rawValue: $0) }
        if kind == nil {
            // If a net and net class share a name, preserve the current kind when possible. A new
            // typed value otherwise resolves to a concrete net before a net class.
            if sim.groundNetKind == .net, groundNetNames.contains(name) {
                kind = .net
            } else if sim.groundNetKind == .netClass, groundNetClassNames.contains(name) {
                kind = .netClass
            } else if groundNetNames.contains(name) {
                kind = .net
            } else if groundNetClassNames.contains(name) {
                kind = .netClass
            }
        }
        guard let kind, sim.groundNetKind != kind || sim.groundNetName != name else {
            updateGroundNameComboBox()
            return
        }
        sim.groundNetKind = kind
        sim.groundNetName = name
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
        updateGroundNameComboBox()
    }

    // MARK: Edge-terminated nets

    func numberOfRows(in tableView: NSTableView) -> Int {
        edgeTerminatedNetRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let comboBox = NetNameComboBox(bordered: false)
        comboBox.controlSize = .small
        comboBox.font = Self.formFont
        comboBox.entries = groundNetNames.map { .name($0, tag: 0) }
        comboBox.stringValue = edgeTerminatedNetRows[row]
        comboBox.isEnabled = selectedSimulation != nil
        comboBox.onCommit = { [weak self, weak comboBox] name, _ in
            guard let self, let comboBox else { return }
            edgeTerminatedNetChanged(comboBox, name: name)
        }
        return comboBox
    }

    /// Accepts a picked menu item, or typed text naming a real net; anything else reverts the row.
    private func edgeTerminatedNetChanged(_ comboBox: NetNameComboBox, name: String) {
        // Looked up afresh rather than trusting the row captured when the cell was made: Return
        // and end-of-editing can both commit, and the first may already have removed a row.
        let row = edgeTerminationTable.row(for: comboBox)
        guard let sim = selectedSimulation, edgeTerminatedNetRows.indices.contains(row) else { return }
        guard groundNetNames.contains(name) else {
            if edgeTerminatedNetRows[row].isEmpty {
                // A row added with (+) and left without picking a net: drop it rather than keep a
                // blank entry around. Deferred so the table isn't edited mid end-editing callback.
                DispatchQueue.main.async { [weak self] in
                    guard let self, edgeTerminationTable.row(for: comboBox) == row,
                          edgeTerminatedNetRows.indices.contains(row),
                          edgeTerminatedNetRows[row].isEmpty else { return }
                    edgeTerminatedNetRows.remove(at: row)
                    commitEdgeTerminatedNets(to: sim)
                    edgeTerminationTable.reloadData()
                }
            } else {
                comboBox.stringValue = edgeTerminatedNetRows[row]
            }
            return
        }
        guard edgeTerminatedNetRows[row] != name else { return }
        edgeTerminatedNetRows[row] = name
        commitEdgeTerminatedNets(to: sim)
    }

    @objc private func addEdgeTerminatedNet() {
        guard let sim = selectedSimulation else { return }
        edgeTerminatedNetRows.append("")
        // A row with no net yet is stored as "" (ignored by slicing), so it survives reloads.
        commitEdgeTerminatedNets(to: sim)
        edgeTerminationTable.reloadData()
        let row = edgeTerminatedNetRows.count - 1
        edgeTerminationTable.scrollRowToVisible(row)
        edgeTerminationTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        (edgeTerminationTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? NetNameComboBox)?
            .beginEditing()
    }

    @objc private func removeEdgeTerminatedNet() {
        guard let sim = selectedSimulation, !edgeTerminatedNetRows.isEmpty else { return }
        let selected = edgeTerminationTable.selectedRow
        edgeTerminatedNetRows.remove(at: edgeTerminatedNetRows.indices.contains(selected)
                                         ? selected : edgeTerminatedNetRows.count - 1)
        commitEdgeTerminatedNets(to: sim)
        edgeTerminationTable.reloadData()
    }

    /// Edge terminations are part of the sliced geometry (SlicedBoard::edgeTerminationLoops), so
    /// any change invalidates this simulation's cached geometry like a ground-net change does.
    private func commitEdgeTerminatedNets(to sim: EMSSimulationBridge) {
        sim.edgeTerminatedNets = edgeTerminatedNetRows
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
    }

    @objc private func numberFieldChanged(_ sender: NSTextField) {
        guard let document else { return }
        var affectsGeometry = false
        var affectsAllGeometry = false
        var affectsFDTD = false
        var affectsResults = false
        switch sender {
        case viaEdgeDistanceField:
            selectedSimulation?.viaEdgeDistance = sender.doubleValue
            affectsGeometry = true
        case viaSpacingField:
            selectedSimulation?.viaSpacing = sender.doubleValue
            affectsGeometry = true
        case eyeBitRateField:
            selectedSimulation?.eyeBitRate = sender.doubleValue
            affectsResults = true
        case platingThicknessField: document.config.viaPlatingThickness = sender.doubleValue
        case fillingEpsilonField: document.config.viaFillingEpsilon = sender.doubleValue
        case frequencyStartField: document.config.frequencyStart = sender.doubleValue
        case frequencyStopField: document.config.frequencyStop = sender.doubleValue
        case maxStepsField:
            document.config.maxSteps = sender.integerValue
            affectsFDTD = true
        case gridDensityField:
            // Document-level, like maxSteps, but unlike maxSteps it genuinely changes the Grid
            // pipeline stage's own output (mesh line placement) -- every simulation's cached
            // geometry needs invalidating, not just whichever one happens to be selected right now.
            document.config.gridDensity = sender.doubleValue
            affectsAllGeometry = true
        case absorbingBoundaryField:
            // Document-level and geometry-changing, exactly like gridDensityField.
            document.config.absorbingBoundaryCells = sender.integerValue
            affectsAllGeometry = true
        default: break
        }
        document.updateChangeCount(.changeDone)
        if affectsAllGeometry {
            for index in document.config.simulations.indices {
                onGeometryParametersChanged?(index)
            }
        } else if affectsGeometry, let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
        if affectsFDTD {
            onFDTDParametersChanged?()
        }
        if affectsResults, let selectedIndex {
            onResultsParametersChanged?(selectedIndex)
        }
        updateDerivedTimingLabels()
    }

    private static let speedOfLightMetersPerSecond = 299_792_458.0

    /// Recomputes maxTimestepLabel/simulationRealTimeLabel from gridDensityField/maxStepsField's
    /// current values -- a quick, isotropic-cell CFL estimate (dt <= cellSize / (c * sqrt(3)), the
    /// stability bound for a cubic Yee cell), not the exact value openEMS's own CalcTimestep would
    /// compute against the real, non-uniform generated mesh (which doesn't exist until the Grid
    /// pipeline stage actually runs, well after this panel's own fields are edited) -- close enough
    /// to sanity-check "is max. timesteps enough simulated time to see this signal decay", the
    /// question these two labels exist to answer at a glance.
    private func updateDerivedTimingLabels() {
        guard let document else {
            maxTimestepValueLabel.stringValue = ""
            simulationRealTimeValueLabel.stringValue = ""
            return
        }
        let cellSizeMeters = document.config.gridDensity * 1e-6
        guard cellSizeMeters > 0 else {
            maxTimestepValueLabel.stringValue = "—"
            simulationRealTimeValueLabel.stringValue = "—"
            return
        }
        let dt = cellSizeMeters / (Self.speedOfLightMetersPerSecond * (3.0 as Double).squareRoot())
        let realTime = dt * Double(document.config.maxSteps)
        maxTimestepValueLabel.stringValue = Self.formatSeconds(dt)
        simulationRealTimeValueLabel.stringValue = Self.formatSeconds(realTime)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if let prefix = SIPrefix.bestFitSmall(for: seconds) {
            return String(format: "%.3g", seconds / prefix.factor) + " \(prefix.symbol)s"
        }
        return String(format: "%.3g", seconds) + " s"
    }
}
