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
    /// Fired after an edit to the template's Tests section. Those settings only affect the eye
    /// analysis, so they're copied to the generated simulations rather than regenerating them
    /// (which would discard their results).
    var onEyeTestChanged: (() -> Void)?

    private let stack = NSStackView()
    private let testsStack = NSStackView()
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
    private lazy var eyeTestSection = EyeTestSectionView { [unowned self] title, control in
        self.row(title, control)
    }

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
        additionalPatternsRow = stacked("Additional Net Patterns:", additionalPatternsTable)
        let rows: [NSView] = [
            row("Excitation IC:", excitationComboBox),
            row("Net Selection:", netSelectionModePopup),
            patternRow!,
            netNamesRow!,
            additionalPatternsRow!,
            row("Phase:", phaseField, indent: Self.indent),
            row("Amplitude:", amplitudeField, indent: Self.indent),
            row("Drive Impedance:", driveImpedanceField, indent: Self.indent),
            row("", probedCheckbox),
            row("", probeNetImpedanceCheckbox),
            row("", absorbingCheckbox),
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

        eyeTestSection.onChange = { [weak self] in self?.onEyeTestChanged?() }
        testsStack.orientation = .vertical
        testsStack.alignment = .leading
        testsStack.addArrangedSubview(eyeTestSection)
        eyeTestSection.widthAnchor.constraint(equalTo: testsStack.widthAnchor).isActive = true
        testsStack.isHidden = true

        let container = NSView()
        let content = NSStackView(views: [stack, testsStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        testsStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        reload()
    }

    // MARK: - Inputs

    func setSimulationIndex(_ index: Int?) {
        simulationIndex = index
        reload()
    }

    func setDisplaySection(_ section: SimulationPropertiesViewController.DisplaySection) {
        stack.isHidden = section == .tests
        testsStack.isHidden = section == .simulation
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
            eyeTestSection.simulation = nil
            return
        }
        eyeTestSection.simulation = simulation
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
        let label = NSTextField(labelWithString: title.hasSuffix(":") ? String(title.dropLast()) : title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .white
        label.alignment = .right
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
        let label = NSTextField(labelWithString: title.hasSuffix(":") ? String(title.dropLast()) : title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .white
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
        let absorbingRow = owner.row("", absorbingCheckbox)
        for view in [headingRow, owner.row("Probed Component:", footprintComboBox),
                     absorbingRow, loadImpedanceRow, loadCapacitanceRow, owner.separator()] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
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
            updateControls()
        }
    }

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let editButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No Patterns")
    private let placeholder: String

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 98) }

    init(title: String = "", placeholder: String = "e.g. DDR_BA$1") {
        self.placeholder = placeholder
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pattern"))
        column.title = title
        tableView.addTableColumn(column)
        if title.isEmpty { tableView.headerView = nil }
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        for (button, symbol, description, action) in [
            (addButton, "plus", "Add pattern", #selector(addPattern)),
            (removeButton, "minus", "Remove pattern", #selector(removePattern)),
            (editButton, "pencil", "Edit pattern", #selector(editPattern)),
        ] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
            button.contentTintColor = .secondaryLabelColor
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        func divider() -> NSView {
            let line = NSBox()
            line.boxType = .separator
            line.heightAnchor.constraint(equalToConstant: 10).isActive = true
            return line
        }
        let buttons = NSStackView(views: [addButton, divider(), removeButton, divider(), editButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 2
        buttons.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let box = ListBoxView()
        box.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        box.addSubview(content)
        for view in [scrollView, emptyLabel, separator, buttons] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor), box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -1),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 76),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: separator.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 20),
        ])
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { patterns.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

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
        let cell = NSTableCellView()
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func addPattern() {
        patterns.append("")
        let row = patterns.count - 1
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        beginEditing(row: row)
        changed()
    }

    @objc private func removePattern() {
        let row = tableView.selectedRow
        guard patterns.indices.contains(row) else { return }
        patterns.remove(at: row)
        tableView.reloadData()
        changed()
    }

    @objc private func editPattern() {
        let row = tableView.selectedRow
        guard patterns.indices.contains(row) else { return }
        beginEditing(row: row)
    }

    @objc private func patternChanged(_ sender: NSTextField) {
        guard patterns.indices.contains(sender.tag) else { return }
        patterns[sender.tag] = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        changed()
    }

    private func changed() {
        onChange?(patterns.filter { !$0.isEmpty })
    }

    private func updateControls() {
        let hasSelection = patterns.indices.contains(tableView.selectedRow)
        emptyLabel.isHidden = !patterns.isEmpty
        removeButton.isEnabled = hasSelection
        editButton.isEnabled = hasSelection
    }

    private func beginEditing(row: Int) {
        tableView.editColumn(0, row: row, with: nil, select: true)
    }
}
