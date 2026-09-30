import Cocoa

/// The "simulation-wide properties" panel: name, ground net, frequency range, via
/// settings. Edits whichever simulation SimulationListViewController has selected (see
/// setSelectedSimulationIndex) -- viaPlatingThickness/viaFillingEpsilon/frequencyStart/frequencyStop
/// stay editable regardless (they're document-level, not per-simulation), but the rest disable
/// themselves when nothing is selected.
/// One row's net picker in the edge-terminated-nets table -- a distinct type so the shared
/// NSComboBoxDelegate callbacks below can tell these apart from the ground-net combo box.
private final class EdgeTerminationComboBox: NSComboBox {}

final class SimulationPropertiesViewController: NSViewController, NSComboBoxDelegate, NSTableViewDataSource,
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

    // Gates SimulationConfig::isDifferentialPair() -- see its own doc comment for exactly what
    // that changes (whether reciprocal net-pair metadata actually gets turned into a diffPairs()
    // entry, or the simulation stays plain single-ended regardless of any such metadata).
    private let differentialPairCheckbox = NSButton(checkboxWithTitle: "Differential Pair", target: nil, action: nil)
    private let nameField = NSTextField(string: "")
    private let groundNameComboBox = NSComboBox()
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

    private var groundNetClassNames: [String] = []
    private var groundNetNames: [String] = []

    private struct GroundMenuChoice {
        let kind: EMSGroundSelectorKind
        let name: String
    }
    private var groundChoicesByComboIndex: [Int: GroundMenuChoice] = [:]
    private var isUpdatingGroundComboBox = false

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

        groundNameComboBox.target = self
        groundNameComboBox.action = #selector(groundNameChanged)
        groundNameComboBox.delegate = self
        groundNameComboBox.controlSize = .small
        groundNameComboBox.font = Self.formFont
        groundNameComboBox.completes = true

        viaEdgeDistanceField.formatter = viaEdgeDistanceFormatter
        viaSpacingField.formatter = viaSpacingFormatter
        platingThicknessField.formatter = platingThicknessFormatter
        fillingEpsilonField.formatter = Self.plainNumberFormatter
        frequencyStartField.formatter = frequencyStartFormatter
        frequencyStopField.formatter = frequencyStopFormatter
        eyeBitRateField.formatter = eyeBitRateFormatter
        maxStepsField.formatter = maxStepsFormatter
        gridDensityField.formatter = gridDensityFormatter

        for field in [viaEdgeDistanceField, viaSpacingField, platingThicknessField,
                      fillingEpsilonField, frequencyStartField, frequencyStopField, maxStepsField,
                      gridDensityField, eyeBitRateField] {
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
        updateDerivedTimingLabels()

        guard let sim = selectedSimulation else {
            nameField.stringValue = ""
            viaEdgeDistanceField.stringValue = ""
            viaSpacingField.stringValue = ""
            eyeBitRateField.stringValue = ""
            differentialPairCheckbox.state = .off
            groundNameComboBox.removeAllItems()
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
        guard let document, let kicadPcbPath = document.config.kicadPcbPath else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let classes = (try? KicadBoardBridge.netClasses(forBoard: kicadPcbPath)) ?? []
            let nets = (try? KicadBoardBridge.allNets(forBoard: kicadPcbPath)) ?? []
            DispatchQueue.main.async {
                self?.groundNetClassNames = classes
                self?.groundNetNames = nets
                self?.updateGroundNameComboBox()
                self?.edgeTerminationTable.reloadData()
            }
        }
    }

    private func updateGroundNameComboBox() {
        guard let sim = selectedSimulation else { return }
        isUpdatingGroundComboBox = true
        defer { isUpdatingGroundComboBox = false }
        groundNameComboBox.removeAllItems()
        groundChoicesByComboIndex.removeAll()
        let font = groundNameComboBox.font ?? Self.formFont

        func addHeading(_ title: String) {
            groundNameComboBox.addItem(withObjectValue: NSAttributedString(
                string: title,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize,
                                                       weight: .semibold),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }

        func addChoices(_ names: [String], kind: EMSGroundSelectorKind) {
            for name in names {
                let index = groundNameComboBox.numberOfItems
                groundNameComboBox.addItem(
                    withObjectValue: NetNameFormatting.attributedString(for: name, font: font))
                groundChoicesByComboIndex[index] = GroundMenuChoice(kind: kind, name: name)
            }
        }

        addHeading("Nets")
        addChoices(groundNetNames, kind: .net)
        groundNameComboBox.addItem(withObjectValue: NSAttributedString(
            string: "────────",
            attributes: [.font: font, .foregroundColor: NSColor.separatorColor]))
        addHeading("Net Classes")
        addChoices(groundNetClassNames, kind: .netClass)

        let selectedIndex = groundChoicesByComboIndex.first {
            let choice = $0.value
            return choice.kind == sim.groundNetKind && choice.name == sim.groundNetName
        }?.key
        if let selectedIndex { groundNameComboBox.selectItem(at: selectedIndex) }
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
        selectedSimulation?.isDifferentialPair = differentialPairCheckbox.state == .on
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

    @objc private func groundNameChanged() {
        guard !isUpdatingGroundComboBox, let sim = selectedSimulation else { return }
        let typedName = groundNameComboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedChoice = groundChoicesByComboIndex[groundNameComboBox.indexOfSelectedItem]
            .flatMap { $0.name == typedName ? $0 : nil }
        var choice = selectedChoice
        if choice == nil {
            // If a net and net class share a name, preserve the current kind when possible. A new
            // typed value otherwise resolves to a concrete net before a net class.
            if sim.groundNetKind == .net, groundNetNames.contains(typedName) {
                choice = GroundMenuChoice(kind: .net, name: typedName)
            } else if sim.groundNetKind == .netClass, groundNetClassNames.contains(typedName) {
                choice = GroundMenuChoice(kind: .netClass, name: typedName)
            } else if groundNetNames.contains(typedName) {
                choice = GroundMenuChoice(kind: .net, name: typedName)
            } else if groundNetClassNames.contains(typedName) {
                choice = GroundMenuChoice(kind: .netClass, name: typedName)
            }
        }
        guard let choice else {
            // Headings, the visual separator, and arbitrary text are not valid model values.
            updateGroundNameComboBox()
            return
        }
        guard sim.groundNetKind != choice.kind || sim.groundNetName != choice.name else {
            updateGroundNameComboBox()
            return
        }
        sim.groundNetKind = choice.kind
        sim.groundNetName = choice.name
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
        updateGroundNameComboBox()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        if let rowComboBox = notification.object as? EdgeTerminationComboBox {
            // The selection lands after this notification; read it on the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in self?.edgeTerminatedNetChanged(rowComboBox) }
            return
        }
        guard let comboBox = notification.object as? NSComboBox,
              comboBox === groundNameComboBox else { return }
        groundNameChanged()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let rowComboBox = notification.object as? EdgeTerminationComboBox {
            edgeTerminatedNetChanged(rowComboBox)
            return
        }
        guard let comboBox = notification.object as? NSComboBox,
              comboBox === groundNameComboBox else { return }
        groundNameChanged()
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        if comboBox is EdgeTerminationComboBox {
            return groundNetNames.first { $0.range(of: string, options: [.anchored, .caseInsensitive]) != nil }
        }
        guard comboBox === groundNameComboBox else { return nil }
        let choices = groundNetNames + groundNetClassNames
        return choices.first { $0.range(of: string, options: [.anchored, .caseInsensitive]) != nil }
    }

    // MARK: Edge-terminated nets

    func numberOfRows(in tableView: NSTableView) -> Int {
        edgeTerminatedNetRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let comboBox = EdgeTerminationComboBox()
        comboBox.controlSize = .small
        comboBox.font = Self.formFont
        comboBox.completes = true
        comboBox.isBordered = false
        comboBox.drawsBackground = false
        comboBox.delegate = self
        comboBox.target = self
        comboBox.action = #selector(edgeTerminatedNetComboBoxAction(_:))
        comboBox.tag = row
        let font = comboBox.font ?? Self.formFont
        for name in groundNetNames {
            comboBox.addItem(withObjectValue: NetNameFormatting.attributedString(for: name, font: font))
        }
        let name = edgeTerminatedNetRows[row]
        if let index = groundNetNames.firstIndex(of: name) { comboBox.selectItem(at: index) }
        comboBox.stringValue = name
        comboBox.isEnabled = selectedSimulation != nil
        return comboBox
    }

    @objc private func edgeTerminatedNetComboBoxAction(_ sender: NSComboBox) {
        guard let rowComboBox = sender as? EdgeTerminationComboBox else { return }
        edgeTerminatedNetChanged(rowComboBox)
    }

    /// Accepts a picked menu item, or typed text naming a real net; anything else reverts the row.
    private func edgeTerminatedNetChanged(_ comboBox: EdgeTerminationComboBox) {
        let row = comboBox.tag
        guard let sim = selectedSimulation, edgeTerminatedNetRows.indices.contains(row) else { return }
        let typed = comboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIndex = comboBox.indexOfSelectedItem
        let name: String
        if groundNetNames.contains(typed) {
            name = typed
        } else if groundNetNames.indices.contains(selectedIndex),
                  NetNameFormatting.attributedString(for: groundNetNames[selectedIndex],
                                                     font: comboBox.font ?? Self.formFont).string == typed {
            name = groundNetNames[selectedIndex]
        } else {
            comboBox.stringValue = edgeTerminatedNetRows[row]
            return
        }
        comboBox.stringValue = name
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
