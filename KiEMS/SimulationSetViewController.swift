import Cocoa

/// The Info column's Simulation Set setup, shown in place of SimulationPropertiesViewController when
/// a Simulation Set is selected in the sidebar and nothing is picked on the board (see
/// WholeBoardViewController.updateConfigurationControls()). Edits the set's
/// EMSSimulationSetBridge -- which pin of which IC is excited, and which pins of other ICs are
/// probed -- and reports each edit through onChanged, which regenerates the set's simulations.
final class SimulationSetViewController: NSViewController {
    private static let formFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let labelWidth: CGFloat = 92
    private static let indent: CGFloat = 16

    private weak var document: Document?
    private var simulationIndex: Int?
    private var footprints: [KicadFootprintInfo] = []

    /// Fired after every edit to the set, once it's been written back to the simulation.
    var onChanged: (() -> Void)?

    private let stack = NSStackView()
    private let excitationComboBox = NSComboBox()
    private let netSelectionModePopup = NSPopUpButton()
    private let patternField = NSTextField(string: "")
    /// Uses the shared Target Membership-style net list: formatted names, autocomplete, and
    /// a compact add/remove/edit footer all stay consistent with the other net editors.
    private let netNamesList = NetListEditorView()
    private let additionalPatternsTable = RegexPatternTableView()
    private let phaseField = NSTextField(string: "")
    private let phaseFormatter = PhaseValueFormatter()
    private let amplitudeField = NSTextField(string: "")
    private let amplitudeFormatter = UnitSuffixValueFormatter(
        displaySuffix: "V", acceptedSuffixes: ["volts", "volt", "v"], autoSelectsSIPrefix: true)
    private let driveImpedanceField = NSTextField(string: "")
    private let driveImpedanceFormatter = SimulationSetViewController.ohmsFormatter()
    private let probedCheckbox = NSButton(checkboxWithTitle: "Probed", target: nil, action: nil)
    private let probeNetImpedanceCheckbox = NSButton(checkboxWithTitle: "Probe Net Impedance", target: nil, action: nil)
    private let absorbingCheckbox = NSButton(checkboxWithTitle: "Absorbing", target: nil, action: nil)
    private let loadImpedanceField = NSTextField(string: "")
    private let loadImpedanceFormatter = SimulationSetViewController.ohmsFormatter()
    private let loadCapacitanceField = NSTextField(string: "")
    private let loadCapacitanceFormatter = SimulationSetViewController.faradsFormatter()
    private var absorbingRows: [NSView] = []
    private let probesStack = NSStackView()
    private let addProbeButton = NSButton(title: "Add Probe", target: nil, action: nil)
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private var patternRow: NSView?
    private var netNamesRow: NSView?
    private var additionalPatternsRow: NSView?

    private static func ohmsFormatter() -> UnitSuffixValueFormatter {
        UnitSuffixValueFormatter(displaySuffix: "Ω", acceptedSuffixes: ["ohms", "ohm", "Ω"], autoSelectsSIPrefix: true)
    }

    private static func faradsFormatter() -> UnitSuffixValueFormatter {
        UnitSuffixValueFormatter(
            displaySuffix: "F", acceptedSuffixes: ["farads", "farad", "f"],
            // Case-sensitive and checked first: a bare lowercase "f" is femto, not farads.
            scaledSuffixes: [(suffix: "fF", factor: 1e-15), (suffix: "f", factor: 1e-15)],
            autoSelectsSIPrefix: true)
    }

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        configureComboBox(excitationComboBox, action: #selector(excitationFootprintChanged))
        netSelectionModePopup.addItems(withTitles: ["Regular Expression", "List"])
        netSelectionModePopup.controlSize = .small
        netSelectionModePopup.font = Self.formFont
        netSelectionModePopup.target = self
        netSelectionModePopup.action = #selector(netSelectionModeChanged)
        configureField(patternField, formatter: nil, action: #selector(patternChanged))
        patternField.placeholderString = "e.g. DDR_ADDR(\\d+)"
        additionalPatternsTable.onChange = { [weak self] patterns in
            guard let self, self.simulation?.simulationSet?.additionalNetPatterns != patterns else { return }
            self.edit { $0.additionalNetPatterns = patterns }
        }
        netNamesList.onChange = { [weak self] names in
            let names = names.filter { !$0.isEmpty }
            guard let self, self.simulation?.simulationSet?.netNames != names else { return }
            self.edit { $0.netNames = names }
        }
        configureField(phaseField, formatter: phaseFormatter, action: #selector(excitationValueChanged))
        configureField(amplitudeField, formatter: amplitudeFormatter, action: #selector(excitationValueChanged))
        configureField(driveImpedanceField, formatter: driveImpedanceFormatter, action: #selector(excitationValueChanged))
        configureField(loadImpedanceField, formatter: loadImpedanceFormatter, action: #selector(excitationValueChanged))
        configureField(loadCapacitanceField, formatter: loadCapacitanceFormatter, action: #selector(excitationValueChanged))
        loadCapacitanceField.placeholderString = "None"
        for checkbox in [probedCheckbox, probeNetImpedanceCheckbox, absorbingCheckbox] {
            configureCheckbox(checkbox, action: #selector(excitationValueChanged))
        }

        addProbeButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)
        addProbeButton.imagePosition = .imageLeading
        addProbeButton.bezelStyle = .push
        addProbeButton.controlSize = .small
        addProbeButton.font = Self.formFont
        addProbeButton.target = self
        addProbeButton.action = #selector(addProbe)

        probesStack.orientation = .vertical
        probesStack.alignment = .leading
        probesStack.spacing = 6

        summaryLabel.font = Self.formFont
        summaryLabel.textColor = .secondaryLabelColor

        let loadImpedanceRow = row("Load Impedance:", loadImpedanceField, indent: Self.indent)
        let loadCapacitanceRow = row("Load Capacitance:", loadCapacitanceField, indent: Self.indent)
        absorbingRows = [loadImpedanceRow, loadCapacitanceRow]
        patternRow = row("Net Name Pattern:", patternField)
        netNamesRow = stacked("Nets to Simulate:", netNamesList)
        additionalPatternsRow = row("Additional Net Patterns:", additionalPatternsTable)
        let rows: [NSView] = [
            row("Excitation IC:", excitationComboBox),
            row("Net Selection:", netSelectionModePopup),
            patternRow!,
            netNamesRow!,
            additionalPatternsRow!,
            row("Phase:", phaseField, indent: Self.indent),
            row("Amplitude:", amplitudeField, indent: Self.indent),
            row("Drive Impedance:", driveImpedanceField, indent: Self.indent),
            probedCheckbox,
            probeNetImpedanceCheckbox,
            absorbingCheckbox,
            loadImpedanceRow,
            loadCapacitanceRow,
            separator(),
            probesStack,
            addProbeButton,
            summaryLabel,
        ]
        for view in rows {
            stack.addArrangedSubview(view)
            if view is NSStackView || view is NSBox || view === summaryLabel {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        stack.setCustomSpacing(12, after: rows[rows.count - 3])

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        reload()
    }

    // MARK: - Inputs

    func setSimulationIndex(_ index: Int?) {
        simulationIndex = index
        reload()
    }

    /// The board's footprints -- the IC choices, and what the summary counts matches against.
    func setFootprints(_ footprints: [KicadFootprintInfo]) {
        self.footprints = footprints
        reload()
    }

    private var simulation: EMSSimulationBridge? {
        guard let document, let simulationIndex, document.config.simulations.indices.contains(simulationIndex)
        else { return nil }
        return document.config.simulations[simulationIndex]
    }

    private func edit(_ change: (EMSSimulationSetBridge) -> Void) {
        guard let simulation, let set = simulation.simulationSet else { return }
        change(set)
        simulation.simulationSet = set
        onChanged?()
        updateSummary(for: set)
    }

    // MARK: - Display

    private func reload() {
        guard isViewLoaded else { return }
        let references = footprints.map(\.reference)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        excitationComboBox.removeAllItems()
        excitationComboBox.addItems(withObjectValues: references)
        guard let set = simulation?.simulationSet else {
            probesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            return
        }
        excitationComboBox.stringValue = set.excitationFootprintReference
        netSelectionModePopup.selectItem(at: set.netSelectionMode == .list ? 1 : 0)
        patternField.stringValue = set.netNamePattern
        netNamesList.rows = set.netNames
        netNamesList.availableNames = NetNameFormatting.sortedForDisplay(
            Array(Set(footprints.flatMap(\.pins).map(\.netName).filter { !$0.isEmpty })))
        additionalPatternsTable.patterns = set.additionalNetPatterns
        phaseField.doubleValue = set.phaseDegrees
        amplitudeField.doubleValue = set.amplitude
        driveImpedanceField.doubleValue = set.driveImpedance
        probedCheckbox.state = set.probed ? .on : .off
        probeNetImpedanceCheckbox.state = set.probeNetImpedance ? .on : .off
        absorbingCheckbox.state = set.absorbing ? .on : .off
        loadImpedanceField.doubleValue = set.loadImpedance
        loadCapacitanceField.objectValue = set.loadCapacitance
        absorbingRows.forEach { $0.isHidden = !set.absorbing }
        updateNetSelectionControls(for: set)
        rebuildProbes(set.probes, references: references)
        updateSummary(for: set)
    }

    private func validatePattern(_ pattern: String) {
        if case .failure = SimulationSetExpansion.regex(for: pattern) {
            patternField.textColor = .systemRed
        } else {
            patternField.textColor = .labelColor
        }
    }

    private func updateNetSelectionControls(for set: EMSSimulationSetBridge) {
        let usesList = set.netSelectionMode == .list
        patternRow?.isHidden = usesList
        netNamesRow?.isHidden = !usesList
        additionalPatternsRow?.isHidden = usesList
        if !usesList { validatePattern(set.netNamePattern) }
    }

    private func updateSummary(for set: EMSSimulationSetBridge) {
        var lines: [String] = []
        if set.netSelectionMode == .regularExpression,
                  case let .failure(error) = SimulationSetExpansion.regex(for: set.netNamePattern) {
            lines.append("Invalid net name pattern: \(error.localizedDescription)")
        } else if set.excitationFootprintReference.isEmpty ||
                    (set.netSelectionMode == .regularExpression && set.netNamePattern.isEmpty) ||
                    (set.netSelectionMode == .list && set.netNames.isEmpty) {
            lines.append("Choose an excitation IC and \(set.netSelectionMode == .list ? "net names" : "a net name pattern").")
        } else if footprints.isEmpty {
            lines.append("Waiting for the board to load…")
        } else if !footprints.contains(where: { $0.reference == set.excitationFootprintReference }) {
            lines.append("No component \(set.excitationFootprintReference) on the board.")
        } else {
            let entries = SimulationSetExpansion.entries(for: set, footprints: footprints)
            lines.append(entries.count == 1 ? "Generates 1 simulation." : "Generates \(entries.count) simulations.")
            let missingSource = entries.filter { $0.sourcePin == nil }.map(\.netName)
            if !missingSource.isEmpty {
                lines.append("No pin on the excitation IC for: \(missingSource.joined(separator: ", "))")
            }
            for (index, probe) in set.probes.enumerated() {
                let matched = entries.reduce(0) { $0 + ($1.probes.indices.contains(index) ? $1.probes[index].pins.count : 0) }
                if matched == 0 && !probe.footprintReference.isEmpty {
                    lines.append("\(probe.footprintReference) has no pins on the matching nets")
                }
            }
        }
        summaryLabel.stringValue = lines.joined(separator: "\n")
    }

    private func rebuildProbes(_ probes: [EMSSimulationSetProbeBridge], references: [String]) {
        probesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, probe) in probes.enumerated() {
            let section = ProbeSectionView(index: index, references: references, owner: self)
            section.configure(with: probe)
            probesStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: probesStack.widthAnchor).isActive = true
        }
    }

    // MARK: - Actions

    @objc private func excitationFootprintChanged() {
        let value = excitationComboBox.stringValue.trimmingCharacters(in: .whitespaces)
        guard simulation?.simulationSet?.excitationFootprintReference != value else { return }
        edit { $0.excitationFootprintReference = value }
    }

    @objc private func patternChanged() {
        let value = patternField.stringValue
        validatePattern(value)
        guard simulation?.simulationSet?.netNamePattern != value else { return }
        edit { $0.netNamePattern = value }
    }

    @objc private func netSelectionModeChanged() {
        let mode: EMSSimulationSetNetSelectionMode = netSelectionModePopup.indexOfSelectedItem == 1 ? .list : .regularExpression
        guard simulation?.simulationSet?.netSelectionMode != mode else { return }
        edit { $0.netSelectionMode = mode }
        if let set = simulation?.simulationSet { updateNetSelectionControls(for: set) }
    }

    @objc private func excitationValueChanged() {
        edit { set in
            set.phaseDegrees = phaseField.doubleValue
            set.amplitude = amplitudeField.doubleValue
            set.driveImpedance = max(0, driveImpedanceField.doubleValue)
            set.probed = probedCheckbox.state == .on
            set.probeNetImpedance = probeNetImpedanceCheckbox.state == .on
            set.absorbing = absorbingCheckbox.state == .on
            set.loadImpedance = max(0, loadImpedanceField.doubleValue)
            set.loadCapacitance = Self.capacitance(from: loadCapacitanceField)
        }
        absorbingRows.forEach { $0.isHidden = absorbingCheckbox.state != .on }
    }

    @objc private func addProbe() {
        edit { $0.probes += [EMSSimulationSetProbeBridge()] }
        reload()
    }

    fileprivate func probeChanged(at index: Int, _ change: (EMSSimulationSetProbeBridge) -> Void) {
        edit { set in
            guard set.probes.indices.contains(index) else { return }
            change(set.probes[index])
        }
    }

    fileprivate func removeProbe(at index: Int) {
        edit { set in
            guard set.probes.indices.contains(index) else { return }
            var probes = set.probes
            probes.remove(at: index)
            set.probes = probes
        }
        reload()
    }

    /// An empty or zero field clears it.
    fileprivate static func capacitance(from field: NSTextField) -> NSNumber? {
        let value = (field.objectValue as? NSNumber)?.doubleValue ?? 0
        return value > 0 ? NSNumber(value: value) : nil
    }

    // MARK: - Building blocks

    fileprivate func configureField(_ field: NSTextField, formatter: Formatter?, target: AnyObject? = nil,
                                    action: Selector) {
        field.formatter = formatter
        field.controlSize = .small
        field.font = Self.formFont
        field.alignment = formatter == nil ? .left : .right
        field.target = target ?? self
        field.action = action
        field.cell?.sendsActionOnEndEditing = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    fileprivate func configureComboBox(_ comboBox: NSComboBox, target: AnyObject? = nil, action: Selector) {
        comboBox.controlSize = .small
        comboBox.font = Self.formFont
        comboBox.completes = true
        comboBox.numberOfVisibleItems = 12
        comboBox.target = target ?? self
        comboBox.action = action
        comboBox.cell?.sendsActionOnEndEditing = true
        comboBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    fileprivate func configureCheckbox(_ checkbox: NSButton, target: AnyObject? = nil, action: Selector) {
        checkbox.controlSize = .small
        checkbox.font = Self.formFont
        checkbox.target = target ?? self
        checkbox.action = action
    }

    fileprivate func row(_ title: String, _ control: NSView, indent: CGFloat = 0) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = Self.formFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth - indent).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        return row
    }

    /// A full-width list needs its title above it, matching the layout used by the other
    /// Target Membership-style net editors in the app.
    fileprivate func stacked(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = Self.formFont
        label.textColor = .secondaryLabelColor
        let column = NSStackView(views: [label, control])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    fileprivate func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

/// One probe's controls in SimulationSetViewController -- its own target/action receiver, since
/// each section has to know which probe it edits.
private final class ProbeSectionView: NSStackView {
    private let index: Int
    private weak var owner: SimulationSetViewController?
    private let footprintComboBox = NSComboBox()
    private let absorbingCheckbox = NSButton(checkboxWithTitle: "Absorbing", target: nil, action: nil)
    private let loadImpedanceField = NSTextField(string: "")
    private let loadImpedanceFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Ω", acceptedSuffixes: ["ohms", "ohm", "Ω"], autoSelectsSIPrefix: true)
    private let loadCapacitanceField = NSTextField(string: "")
    private let loadCapacitanceFormatter = UnitSuffixValueFormatter(
        displaySuffix: "F", acceptedSuffixes: ["farads", "farad", "f"],
        scaledSuffixes: [(suffix: "fF", factor: 1e-15), (suffix: "f", factor: 1e-15)],
        autoSelectsSIPrefix: true)
    private var absorbingRows: [NSView] = []

    init(index: Int, references: [String], owner: SimulationSetViewController) {
        self.index = index
        self.owner = owner
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        let heading = NSTextField(labelWithString: "Probe \(index + 1)")
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let removeButton = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove probe")!,
                                    target: self, action: #selector(remove))
        removeButton.isBordered = false
        removeButton.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let headingRow = NSStackView(views: [heading, spacer, removeButton])
        headingRow.orientation = .horizontal

        owner.configureComboBox(footprintComboBox, target: self, action: #selector(changed))
        footprintComboBox.addItems(withObjectValues: references)
        owner.configureCheckbox(absorbingCheckbox, target: self, action: #selector(changed))
        owner.configureField(loadImpedanceField, formatter: loadImpedanceFormatter, target: self,
                             action: #selector(changed))
        owner.configureField(loadCapacitanceField, formatter: loadCapacitanceFormatter, target: self,
                             action: #selector(changed))
        loadCapacitanceField.placeholderString = "None"

        let loadImpedanceRow = owner.row("Load Impedance:", loadImpedanceField, indent: 16)
        let loadCapacitanceRow = owner.row("Load Capacitance:", loadCapacitanceField, indent: 16)
        absorbingRows = [loadImpedanceRow, loadCapacitanceRow]
        for view in [headingRow, owner.row("Probed Component:", footprintComboBox),
                     absorbingCheckbox, loadImpedanceRow, loadCapacitanceRow, owner.separator()] {
            addArrangedSubview(view)
            if view !== absorbingCheckbox {
                view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with probe: EMSSimulationSetProbeBridge) {
        footprintComboBox.stringValue = probe.footprintReference
        absorbingCheckbox.state = probe.absorbing ? .on : .off
        loadImpedanceField.doubleValue = probe.loadImpedance
        loadCapacitanceField.objectValue = probe.loadCapacitance
        absorbingRows.forEach { $0.isHidden = !probe.absorbing }
    }

    @objc private func changed() {
        let footprint = footprintComboBox.stringValue.trimmingCharacters(in: .whitespaces)
        let absorbing = absorbingCheckbox.state == .on
        let loadImpedance = max(0, loadImpedanceField.doubleValue)
        let loadCapacitance = SimulationSetViewController.capacitance(from: loadCapacitanceField)
        absorbingRows.forEach { $0.isHidden = !absorbing }
        owner?.probeChanged(at: index) { probe in
            probe.footprintReference = footprint
            probe.absorbing = absorbing
            probe.loadImpedance = loadImpedance
            probe.loadCapacitance = loadCapacitance
        }
    }

    @objc private func remove() {
        owner?.removeProbe(at: index)
    }
}

/// A compact, editable list of regex substitutions.  A table keeps each pattern distinct (unlike
/// newline-separated text) and makes adding/removing mappings discoverable.
private final class RegexPatternTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: (([String]) -> Void)?

    var patterns: [String] = [] {
        didSet {
            guard patterns != oldValue else { return }
            tableView.reloadData()
        }
    }

    private let tableView = NSTableView()
    private let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add pattern")!,
                                     target: nil, action: nil)
    private let removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove pattern")!,
                                        target: nil, action: nil)
    private let placeholder: String

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 78) }

    init(title: String = "", placeholder: String = "e.g. DDR_BA$1") {
        self.placeholder = placeholder
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pattern"))
        column.title = title
        tableView.addTableColumn(column)
        if title.isEmpty { tableView.headerView = nil }
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        for button in [addButton, removeButton] {
            button.isBordered = false
            button.controlSize = .small
            button.target = self
        }
        addButton.action = #selector(addPattern)
        removeButton.action = #selector(removePattern)
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .vertical
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -3),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { patterns.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(string: patterns[row])
        field.isBordered = false
        field.backgroundColor = .clear
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = placeholder
        field.tag = row
        field.target = self
        field.action = #selector(patternChanged(_:))
        field.cell?.sendsActionOnEndEditing = true
        return field
    }

    @objc private func addPattern() {
        patterns.append("")
        let row = patterns.count - 1
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.editColumn(0, row: row, with: nil, select: true)
        changed()
    }

    @objc private func removePattern() {
        let row = tableView.selectedRow
        guard patterns.indices.contains(row) else { return }
        patterns.remove(at: row)
        tableView.reloadData()
        changed()
    }

    @objc private func patternChanged(_ sender: NSTextField) {
        guard patterns.indices.contains(sender.tag) else { return }
        patterns[sender.tag] = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        changed()
    }

    private func changed() {
        onChange?(patterns.filter { !$0.isEmpty })
    }
}
