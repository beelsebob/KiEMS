import Cocoa

/// A unit-suffixed field whose empty value means "inherit" -- UnitSuffixValueFormatter itself
/// rejects an empty string, which would trap the user in the field once an override was set.
private final class OptionalUnitFormatter: Formatter {
    private let wrapped: UnitSuffixValueFormatter

    init(_ wrapped: UnitSuffixValueFormatter) {
        self.wrapped = wrapped
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func string(for obj: Any?) -> String? {
        obj == nil ? "" : wrapped.string(for: obj)
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                  errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            obj?.pointee = nil
            return true
        }
        return wrapped.getObjectValue(obj, for: string, errorDescription: error)
    }
}

/// The Info column's content while Board Setup is selected (see WholeBoardViewController.
/// setBoardSetupMode): the board-wide defaults when nothing is picked on the board, otherwise the
/// picked net's, net class's and pin's own board-level settings. Every edit goes straight into
/// document.config.boardSetup; simulations take these values as their nets are included (see
/// WholeBoardViewController.applyBoardDefaults).
final class BoardSetupViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let formFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let labelWidth: CGFloat = 95

    struct Target: Equatable {
        /// The picked nets; with several, every net control edits all of them and shows
        /// "<multiple values>" wherever they disagree.
        var nets: [String] = []
        /// The picked nets' distinct net classes, edited together the same way.
        var netClasses: [String] = []
        var isNetClassLoading = false

        /// The one picked net, if exactly one.
        var net: String? { nets.count == 1 ? nets[0] : nil }
        var netClass: String? { netClasses.count == 1 ? netClasses[0] : nil }
        /// The picked pins; with several, every pin control edits all of them and shows
        /// "<multiple values>" wherever they disagree.
        var pins: [BoardPinRef] = []
        /// User-facing labels for `pins`, in the same order.
        var pinLabels: [String] = []
        /// The picked components, by reference, edited together the same way.
        var components: [String] = []
        /// Picked components that can't be simulated (no R/L/C-only SPICE model, or models not yet
        /// loaded) -- they can be removed from Board Setup but not added.
        var unusableComponents: Set<String> = []
        /// Why picked components can't be simulated, and any note (models still loading).
        var componentWarnings: [String] = []
        var componentNote: String?
        /// Per entry of `pins`: whether the automatic termination rule absorbs it when no explicit
        /// choice is set.
        var defaultAbsorbing: [Bool] = []
    }

    private static let multipleValues = "<multiple values>"

    private weak var document: Document?
    private var target: Target?
    private var netClassNames: [String] = []
    private var netNames: [String] = []

    /// Any board-setup edit -- marks the document dirty; nothing downstream is invalidated, since
    /// simulations only copy these values when nets are included.
    var onChanged: (() -> Void)?
    /// The frequency range is the document's own (shared with every simulation's settings), so
    /// changing it here invalidates results exactly as editing it there does.
    var onFrequencyRangeChanged: (() -> Void)?

    private static func ohmsFormatter() -> UnitSuffixValueFormatter {
        UnitSuffixValueFormatter(displaySuffix: "Ω", acceptedSuffixes: ["ohms", "ohm", "Ω"], autoSelectsSIPrefix: true)
    }

    private static func hertzFormatter() -> UnitSuffixValueFormatter {
        UnitSuffixValueFormatter(displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    }

    // Board
    private let boardSection = NSStackView()
    private let groundNameComboBox = NetNameComboBox()
    private let edgeTerminationList = NetListEditorView()
    private let signalImpedanceField = NSTextField(string: "")
    private let powerImpedanceField = NSTextField(string: "")
    private let netClassTable = NSTableView()
    private let netClassScroll = NSScrollView()
    private let frequencyStartField = NSTextField(string: "")
    private let frequencyStopField = NSTextField(string: "")
    private let bitRateField = NSTextField(string: "")
    private let bitRateFormatter = OptionalUnitFormatter(UnitSuffixValueFormatter(
        displaySuffix: "bit/s", acceptedSuffixes: ["bit/s", "bps"],
        scaledSuffixes: SIPrefix.allCases.flatMap { prefix in
            prefix.inputSymbols.flatMap { symbol in
                [
                    (suffix: "\(symbol)b/s", factor: prefix.factor),
                    (suffix: "\(symbol)B/s", factor: 8 * prefix.factor),
                ]
            }
        },
        autoSelectsSIPrefix: true))

    // Pin
    private let pinSection = NSStackView()
    private let pinHeading = NSTextField(labelWithString: "")
    private let pinIncludedCheckbox = NSButton(checkboxWithTitle: "Included in simulation", target: nil, action: nil)
    private let pinAbsorbsAtHullCheckbox = NSButton(checkboxWithTitle: "Edge terminated", target: nil, action: nil)
    private let pinImpedanceField = NSTextField(string: "")
    private let absorbingCheckbox = NSButton(checkboxWithTitle: "Absorbing", target: nil, action: nil)
    private let noiseCheckbox = NSButton(checkboxWithTitle: "Noise Generating", target: nil, action: nil)
    private let noiseFrequencyField = NSTextField(string: "")
    private let noiseAmplitudeField = NSTextField(string: "")
    private let noiseControls = NSStackView()

    // Net / net class
    private let componentSection = NSStackView()
    private let componentHeading = NSTextField(labelWithString: "")
    private let componentIncludedCheckbox = NSButton(checkboxWithTitle: "Included in Simulation", target: nil, action: nil)
    private let componentWarningBox = ComponentWarningBox(textWidth: 224)

    private let netSection = NSStackView()
    private let netNameView = NetNameView()
    private let netIncludedCheckbox = NSButton(checkboxWithTitle: "Included in simulation", target: nil, action: nil)
    private let netAbsorbsAtHullCheckbox = NSButton(checkboxWithTitle: "Edge terminated", target: nil, action: nil)
    private let netImpedanceField = NSTextField(string: "")
    private let netClassSection = NSStackView()
    private let netClassNameView = NetNameView()
    private let netClassIncludedCheckbox = NSButton(checkboxWithTitle: "Included in simulation", target: nil, action: nil)
    private let netClassImpedanceField = NSTextField(string: "")

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var boardSetup: EMSBoardSetupBridge? { document?.config.boardSetup }

    override func loadView() {
        view = NSView()
        buildUI()
        reload()
    }

    // MARK: - Layout

    private func labeled(_ title: String, _ control: NSView, indent: CGFloat = 0) -> NSStackView {
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
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func headingRow(_ prefix: String, _ nameView: NetNameView) -> NSStackView {
        let row = NSStackView(views: [heading(prefix), nameView])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 4
        return row
    }

    private func configureColumn(_ stack: NSStackView, _ views: [NSView]) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func configureField(_ field: NSTextField, formatter: Formatter, action: Selector) {
        field.formatter = formatter
        field.controlSize = .small
        field.font = Self.formFont
        field.alignment = .right
        field.target = self
        field.action = action
    }

    private func buildUI() {
        configureField(signalImpedanceField, formatter: Self.ohmsFormatter(), action: #selector(boardFieldChanged(_:)))
        configureField(powerImpedanceField, formatter: Self.ohmsFormatter(), action: #selector(boardFieldChanged(_:)))
        configureField(frequencyStartField, formatter: Self.hertzFormatter(), action: #selector(boardFieldChanged(_:)))
        configureField(frequencyStopField, formatter: Self.hertzFormatter(), action: #selector(boardFieldChanged(_:)))
        configureField(bitRateField, formatter: bitRateFormatter, action: #selector(boardFieldChanged(_:)))
        bitRateField.placeholderString = "Automatic"

        let rangeSeparator = NSTextField(labelWithString: "–")
        rangeSeparator.font = Self.formFont
        rangeSeparator.textColor = .secondaryLabelColor
        rangeSeparator.setContentHuggingPriority(.required, for: .horizontal)
        let frequencyRange = NSStackView(views: [frequencyStartField, rangeSeparator, frequencyStopField])
        frequencyRange.orientation = .horizontal
        frequencyRange.alignment = .centerY
        frequencyRange.spacing = 3
        frequencyStartField.widthAnchor.constraint(equalTo: frequencyStopField.widthAnchor).isActive = true

        groundNameComboBox.controlSize = .small
        groundNameComboBox.font = Self.formFont
        groundNameComboBox.onCommit = { [weak self] name, tag in self?.groundNameChanged(name, tag: tag) }
        edgeTerminationList.onChange = { [weak self] rows in
            self?.boardSetup?.edgeTerminatedNets = rows
            self?.onChanged?()
        }
        let edgeTerminationLabel = NSTextField(labelWithString: "Edge Terminated Nets:")
        edgeTerminationLabel.font = Self.formFont

        let netClassLabel = NSTextField(labelWithString: "Net Class Impedance:")
        netClassLabel.font = Self.formFont
        configureColumn(boardSection, [
            labeled("Ground Net:", groundNameComboBox),
            edgeTerminationLabel,
            edgeTerminationList,
            separator(),
            labeled("Signal Nets:", signalImpedanceField),
            labeled("Power Nets:", powerImpedanceField),
            netClassLabel,
            buildNetClassTable(),
            separator(),
            labeled("Signal Frequency:", frequencyRange),
            labeled("Digital Bitrate:", bitRateField),
        ])
        boardSection.setCustomSpacing(10, after: edgeTerminationList)
        boardSection.setCustomSpacing(10, after: boardSection.arrangedSubviews[3])
        boardSection.setCustomSpacing(10, after: boardSection.arrangedSubviews[7])
        boardSection.setCustomSpacing(10, after: boardSection.arrangedSubviews[8])

        // Pin
        pinHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        configureField(pinImpedanceField, formatter: OptionalUnitFormatter(Self.ohmsFormatter()),
                       action: #selector(pinImpedanceChanged))
        // Optional only so a "<multiple values>" field can be left empty, keeping each pin's own value.
        configureField(noiseFrequencyField, formatter: OptionalUnitFormatter(Self.hertzFormatter()),
                       action: #selector(noiseChanged(_:)))
        configureField(noiseAmplitudeField,
                       formatter: OptionalUnitFormatter(UnitSuffixValueFormatter(
                           displaySuffix: "V", acceptedSuffixes: ["volts", "volt", "v"], autoSelectsSIPrefix: true)),
                       action: #selector(noiseChanged(_:)))
        for checkbox in [pinIncludedCheckbox, pinAbsorbsAtHullCheckbox, absorbingCheckbox, noiseCheckbox,
                         netIncludedCheckbox, netAbsorbsAtHullCheckbox, netClassIncludedCheckbox,
                         componentIncludedCheckbox] {
            checkbox.controlSize = .small
            checkbox.font = Self.formFont
            checkbox.target = self
        }
        pinIncludedCheckbox.action = #selector(pinIncludedToggled)
        netIncludedCheckbox.action = #selector(netIncludedToggled)
        pinAbsorbsAtHullCheckbox.action = #selector(pinAbsorbsAtHullToggled)
        netAbsorbsAtHullCheckbox.action = #selector(netAbsorbsAtHullToggled)
        netClassIncludedCheckbox.action = #selector(netClassIncludedToggled)
        absorbingCheckbox.action = #selector(absorbingToggled)
        noiseCheckbox.action = #selector(noiseChanged(_:))
        componentIncludedCheckbox.action = #selector(componentIncludedToggled)
        componentHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        configureColumn(componentSection, [componentHeading, componentWarningBox, labeled("", componentIncludedCheckbox),
                                           separator()])
        configureColumn(noiseControls, [
            labeled("Frequency:", noiseFrequencyField, indent: 16),
            labeled("Amplitude:", noiseAmplitudeField, indent: 16),
        ])
        noiseControls.spacing = 4
        configureColumn(pinSection, [
            pinHeading,
            labeled("", pinIncludedCheckbox),
            labeled("", pinAbsorbsAtHullCheckbox),
            labeled("Impedance:", pinImpedanceField),
            labeled("", absorbingCheckbox),
            labeled("", noiseCheckbox),
            noiseControls,
            separator(),
        ])

        // Net / net class
        configureField(netImpedanceField, formatter: OptionalUnitFormatter(Self.ohmsFormatter()),
                       action: #selector(netImpedanceChanged))
        configureField(netClassImpedanceField, formatter: OptionalUnitFormatter(Self.ohmsFormatter()),
                       action: #selector(netClassImpedanceChanged))
        configureColumn(netSection, [
            headingRow("Net:", netNameView),
            labeled("", netIncludedCheckbox),
            labeled("", netAbsorbsAtHullCheckbox),
            labeled("Impedance:", netImpedanceField),
            separator(),
        ])
        configureColumn(netClassSection, [
            headingRow("Net Class:", netClassNameView),
            labeled("", netClassIncludedCheckbox),
            labeled("Impedance:", netClassImpedanceField),
        ])

        let sections = [boardSection, componentSection, pinSection, netSection, netClassSection]
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    private static let nameColumn = NSUserInterfaceItemIdentifier("netClass")
    private static let impedanceColumn = NSUserInterfaceItemIdentifier("impedance")

    private func buildNetClassTable() -> NSView {
        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = "Net Class"
        let impedance = NSTableColumn(identifier: Self.impedanceColumn)
        impedance.title = "Impedance"
        impedance.width = 78
        netClassTable.addTableColumn(name)
        netClassTable.addTableColumn(impedance)
        netClassTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        netClassTable.controlSize = .small
        netClassTable.rowHeight = 20
        netClassTable.usesAlternatingRowBackgroundColors = true
        netClassTable.style = .plain
        netClassTable.dataSource = self
        netClassTable.delegate = self

        netClassScroll.documentView = netClassTable
        netClassScroll.hasVerticalScroller = true
        netClassScroll.borderType = .bezelBorder
        netClassScroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        return netClassScroll
    }

    // MARK: - State

    /// nil shows the board-wide defaults.
    func setTarget(_ target: Target?) {
        self.target = target
        guard isViewLoaded else { return }
        reload()
    }

    /// Called whenever the linked board changes -- the table lists its net classes.
    func refreshBoardData() {
        guard let board = document?.board else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let classes = (try? board.netClasses()) ?? []
            let nets = (try? board.allNets()) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.netClassNames = NetNameFormatting.sortedForDisplay(classes)
                self.netNames = NetNameFormatting.sortedForDisplay(nets)
                self.netClassTable.reloadData()
                self.edgeTerminationList.availableNames = self.netNames
                self.updateGroundNameComboBox()
            }
        }
    }

    /// The impedance `net` would get from its class/the defaults, ignoring its own override.
    private func inheritedNetImpedance(net: String, netClass: String?) -> Double {
        guard let boardSetup else { return 45 }
        if let netClass, let value = boardSetup.impedance(forNetClass: netClass) { return value.doubleValue }
        return PowerNetHeuristic.isPowerNet(net) ? boardSetup.powerImpedance : boardSetup.signalImpedance
    }

    private func effectiveNetImpedance(net: String, netClass: String?) -> Double {
        boardSetup?.impedance(forNet: net)?.doubleValue ?? inheritedNetImpedance(net: net, netClass: netClass)
    }

    private func formattedOhms(_ value: Double) -> String {
        Self.ohmsFormatter().string(for: NSNumber(value: value)) ?? ""
    }

    func reload() {
        guard let document, let boardSetup else { return }
        let showsBoard = target == nil
        boardSection.isHidden = !showsBoard
        if showsBoard {
            updateGroundNameComboBox()
            edgeTerminationList.rows = boardSetup.edgeTerminatedNets
            signalImpedanceField.doubleValue = boardSetup.signalImpedance
            powerImpedanceField.doubleValue = boardSetup.powerImpedance
            frequencyStartField.doubleValue = document.config.frequencyStart
            frequencyStopField.doubleValue = document.config.frequencyStop
            bitRateField.objectValue = boardSetup.bitRate > 0 ? NSNumber(value: boardSetup.bitRate) : nil
            netClassTable.reloadData()
        }

        let nets = targetNets
        let netClasses = targetNetClasses
        let net = target?.net
        let netClass = target?.netClass

        netSection.isHidden = nets.isEmpty
        if !nets.isEmpty {
            netNameView.configure(name: net ?? Self.multipleValues, font: .systemFont(ofSize: 13))
            let includedNets = Set(boardSetup.includedNets)
            let included = nets.map { includedNets.contains($0) }
            setCheckbox(netIncludedCheckbox, included)
            netAbsorbsAtHullCheckbox.isEnabled = included.allSatisfy { $0 }
            let terminatedNets = Set(boardSetup.edgeTerminatedNets)
            setCheckbox(netAbsorbsAtHullCheckbox, nets.map { terminatedNets.contains($0) })
            let impedances = Set(nets.map { boardSetup.impedance(forNet: $0)?.doubleValue })
            netImpedanceField.objectValue = impedances.count == 1 ? impedances.first!.map { NSNumber(value: $0) } : nil
            if impedances.count > 1 {
                netImpedanceField.placeholderString = Self.multipleValues
            } else {
                // A single net's own class is known; several nets' classes aren't mapped per net.
                let inherited = Set(nets.map { inheritedNetImpedance(net: $0, netClass: nets.count == 1 ? netClass : nil) })
                netImpedanceField.placeholderString = inherited.count == 1 ? formattedOhms(inherited.first!)
                    : Self.multipleValues
            }
        }

        netClassSection.isHidden = target == nil || (netClasses.isEmpty && !(target?.isNetClassLoading ?? false))
        netClassImpedanceField.isEnabled = !netClasses.isEmpty
        netClassIncludedCheckbox.isEnabled = !netClasses.isEmpty
        let includedClasses = Set(boardSetup.includedNetClasses)
        setCheckbox(netClassIncludedCheckbox, netClasses.map { includedClasses.contains($0) })
        netClassNameView.configure(name: target?.isNetClassLoading == true ? "Loading…"
                                       : netClass ?? (netClasses.isEmpty ? "" : Self.multipleValues),
                                   font: .systemFont(ofSize: 13))
        let classImpedances = Set(netClasses.map { boardSetup.impedance(forNetClass: $0)?.doubleValue })
        netClassImpedanceField.objectValue = classImpedances.count == 1
            ? classImpedances.first!.map { NSNumber(value: $0) } : nil
        netClassImpedanceField.placeholderString = classImpedances.count > 1 ? Self.multipleValues
            : formattedOhms(boardSetup.signalImpedance)

        let components = target?.components ?? []
        componentSection.isHidden = components.isEmpty
        if !components.isEmpty {
            componentHeading.stringValue = components.count == 1 ? "Component: \(components[0])"
                : "\(components.count) Components"
            let includedComponents = Set(boardSetup.includedComponents)
            let included = components.map { includedComponents.contains($0) }
            setCheckbox(componentIncludedCheckbox, included)
            // Unusable parts can only be taken out, never put in.
            let unusable = target?.unusableComponents ?? []
            componentWarningBox.show(target?.componentWarnings ?? [], note: target?.componentNote)
            componentIncludedCheckbox.isEnabled = zip(components, included).contains { !unusable.contains($0) || $1 }
        }

        let pins = target?.pins ?? []
        guard !pins.isEmpty else {
            pinSection.isHidden = true
            return
        }
        pinSection.isHidden = false
        if pins.count == 1 {
            let fallback = "\(pins[0].reference)/\(pins[0].number)(\(pins[0].number))"
            pinHeading.stringValue = "Pin: \(target?.pinLabels.first ?? fallback)"
        } else {
            pinHeading.stringValue = "\(pins.count) Pins"
        }
        let setups = pins.map { boardSetup.pin(withFootprint: $0.reference, pin: $0.number) }

        let includedNets = Set(boardSetup.includedNets)
        let pinNets = pinNetNames(pins)
        pinIncludedCheckbox.isEnabled = !pinNets.isEmpty
        setCheckbox(pinIncludedCheckbox, pinNets.map { includedNets.contains($0) })
        let terminatedNets = Set(boardSetup.edgeTerminatedNets)
        pinAbsorbsAtHullCheckbox.isEnabled = !pinNets.isEmpty && pinNets.allSatisfy { includedNets.contains($0) }
        setCheckbox(pinAbsorbsAtHullCheckbox, pinNets.map { terminatedNets.contains($0) })

        let impedances = Set(setups.map { $0?.impedance?.doubleValue })
        pinImpedanceField.objectValue = impedances.count == 1 ? impedances.first!.map { NSNumber(value: $0) } : nil
        if impedances.count > 1 {
            pinImpedanceField.placeholderString = Self.multipleValues
        } else {
            let inherited = Set(pins.compactMap { pin in
                (pin.net ?? net).map { effectiveNetImpedance(net: $0, netClass: pins.count == 1 ? netClass : nil) }
            })
            pinImpedanceField.placeholderString = inherited.count == 1 ? formattedOhms(inherited.first!)
                : inherited.isEmpty ? nil : Self.multipleValues
        }

        let defaults = target?.defaultAbsorbing ?? []
        setCheckbox(absorbingCheckbox, setups.enumerated().map { index, setup in
            setup?.absorbing?.boolValue ?? (index < defaults.count && defaults[index])
        })
        let noise = setups.map { $0?.noiseGenerating ?? false }
        setCheckbox(noiseCheckbox, noise)
        noiseControls.isHidden = !noise.contains(true)
        let frequencies = Set(setups.map { $0?.noiseFrequency ?? defaultNoiseFrequency })
        let amplitudes = Set(setups.map { $0?.noiseAmplitude ?? 1 })
        for (field, values) in [(noiseFrequencyField, frequencies), (noiseAmplitudeField, amplitudes)] {
            field.objectValue = values.count == 1 ? NSNumber(value: values.first!) : nil
            field.placeholderString = values.count == 1 ? nil : Self.multipleValues
        }
    }

    /// Mixed state only while the pins disagree; a click then turns it on for all of them.
    private func setCheckbox(_ checkbox: NSButton, _ values: [Bool]) {
        let mixed = Set(values).count > 1
        checkbox.allowsMixedState = mixed
        checkbox.state = mixed ? .mixed : values.first == true ? .on : .off
    }

    private func committedCheckboxState(_ checkbox: NSButton) -> Bool {
        if checkbox.state == .mixed { checkbox.state = .on }
        checkbox.allowsMixedState = false
        return checkbox.state == .on
    }

    /// 100 MHz, kept inside the board's signal frequency range.
    private var defaultNoiseFrequency: Double {
        guard let config = document?.config else { return 100e6 }
        let low = min(config.frequencyStart, config.frequencyStop)
        let high = max(config.frequencyStart, config.frequencyStop)
        return min(max(100e6, low), high)
    }

    private func updateGroundNameComboBox() {
        groundNameComboBox.entries = [.heading("Nets")]
            + netNames.map { .name($0, tag: EMSGroundSelectorKind.net.rawValue) }
            + [.separator, .heading("Net Classes")]
            + netClassNames.map { .name($0, tag: EMSGroundSelectorKind.netClass.rawValue) }
        groundNameComboBox.stringValue = boardSetup?.groundNetName ?? ""
    }

    // MARK: - Actions

    /// `tag` is the picked menu entry's EMSGroundSelectorKind, or nil for typed text -- accepted
    /// only if it names a real net or net class (a net first); empty text clears the choice.
    private func groundNameChanged(_ name: String, tag: Int?) {
        guard let boardSetup else { return }
        if name.isEmpty {
            boardSetup.groundNetName = nil
            changed()
            return
        }
        var kind = tag.flatMap { EMSGroundSelectorKind(rawValue: $0) }
        if kind == nil {
            if boardSetup.groundNetKind == .netClass, netClassNames.contains(name) {
                kind = .netClass
            } else if netNames.contains(name) {
                kind = .net
            } else if netClassNames.contains(name) {
                kind = .netClass
            }
        }
        guard let kind, boardSetup.groundNetKind != kind || boardSetup.groundNetName != name else {
            updateGroundNameComboBox()
            return
        }
        boardSetup.groundNetKind = kind
        boardSetup.groundNetName = name
        changed()
    }

    @objc private func boardFieldChanged(_ sender: NSTextField) {
        guard let document, let boardSetup else { return }
        switch sender {
        case signalImpedanceField: boardSetup.signalImpedance = sender.doubleValue
        case powerImpedanceField: boardSetup.powerImpedance = sender.doubleValue
        case bitRateField: boardSetup.bitRate = (sender.objectValue as? NSNumber)?.doubleValue ?? 0
        case frequencyStartField, frequencyStopField:
            if sender === frequencyStartField {
                document.config.frequencyStart = sender.doubleValue
            } else {
                document.config.frequencyStop = sender.doubleValue
            }
            onFrequencyRangeChanged?()
        default: return
        }
        changed()
    }

    private var targetNets: [String] { (target?.nets ?? []).filter { !$0.isEmpty } }
    private var targetNetClasses: [String] { (target?.netClasses ?? []).filter { !$0.isEmpty } }

    @objc private func netImpedanceChanged() {
        let nets = targetNets
        guard !nets.isEmpty else { return }
        let value = netImpedanceField.objectValue as? NSNumber
        // Leaving a "<multiple values>" field empty keeps each net's own override.
        if value == nil, netImpedanceField.placeholderString == Self.multipleValues { return }
        for net in nets { boardSetup?.setImpedance(value, forNet: net) }
        changed()
    }

    @objc private func netClassImpedanceChanged() {
        let netClasses = targetNetClasses
        guard !netClasses.isEmpty else { return }
        let value = netClassImpedanceField.objectValue as? NSNumber
        if value == nil, netClassImpedanceField.placeholderString == Self.multipleValues { return }
        for netClass in netClasses { boardSetup?.setImpedance(value, forNetClass: netClass) }
        changed()
    }

    /// The picked pins' nets, in order and without duplicates; unconnected pins have none.
    private func pinNetNames(_ pins: [BoardPinRef]) -> [String] {
        var seen = Set<String>()
        return pins.compactMap { pin in
            guard let net = pin.net ?? target?.net, !net.isEmpty, seen.insert(net).inserted else { return nil }
            return net
        }
    }

    private func setNets(_ nets: [String], included: Bool) {
        guard let boardSetup else { return }
        var current = boardSetup.includedNets.filter { !nets.contains($0) }
        if included { current += nets }
        boardSetup.includedNets = current
        changed()
    }

    /// A pin is included through its net -- simulations have no per-pin inclusion of their own.
    @objc private func pinIncludedToggled() {
        guard let pins = target?.pins, !pins.isEmpty else { return }
        setNets(pinNetNames(pins), included: committedCheckboxState(pinIncludedCheckbox))
    }

    @objc private func netIncludedToggled() {
        let nets = targetNets
        guard !nets.isEmpty else { return }
        setNets(nets, included: committedCheckboxState(netIncludedCheckbox))
    }

    /// Hull-boundary absorption is Board Setup's edge termination (edgeTerminatedNets), per net.
    private func setNets(_ nets: [String], absorbAtHull: Bool) {
        guard let boardSetup else { return }
        var current = boardSetup.edgeTerminatedNets.filter { !nets.contains($0) }
        if absorbAtHull { current += nets }
        boardSetup.edgeTerminatedNets = current
        changed()
    }

    @objc private func pinAbsorbsAtHullToggled() {
        guard let pins = target?.pins, !pins.isEmpty else { return }
        setNets(pinNetNames(pins), absorbAtHull: committedCheckboxState(pinAbsorbsAtHullCheckbox))
    }

    @objc private func netAbsorbsAtHullToggled() {
        let nets = targetNets
        guard !nets.isEmpty else { return }
        setNets(nets, absorbAtHull: committedCheckboxState(netAbsorbsAtHullCheckbox))
    }

    /// Adds every usable picked component, or removes every picked one.
    @objc private func componentIncludedToggled() {
        guard let components = target?.components, !components.isEmpty, let boardSetup else { return }
        let include = committedCheckboxState(componentIncludedCheckbox)
        let unusable = target?.unusableComponents ?? []
        var current = boardSetup.includedComponents.filter { !components.contains($0) }
        if include { current += components.filter { !unusable.contains($0) } }
        boardSetup.includedComponents = current
        changed()
    }

    @objc private func netClassIncludedToggled() {
        let netClasses = targetNetClasses
        guard !netClasses.isEmpty, let boardSetup else { return }
        var current = boardSetup.includedNetClasses.filter { !netClasses.contains($0) }
        if committedCheckboxState(netClassIncludedCheckbox) { current += netClasses }
        boardSetup.includedNetClasses = current
        changed()
    }

    @objc private func pinImpedanceChanged() {
        guard let pins = target?.pins, !pins.isEmpty else { return }
        let value = pinImpedanceField.objectValue as? NSNumber
        // Leaving a "<multiple values>" field empty keeps each pin's own override.
        if value == nil, pinImpedanceField.placeholderString == Self.multipleValues { return }
        for pin in pins {
            boardSetup?.setImpedance(value, forFootprint: pin.reference, pin: pin.number)
        }
        changed()
    }

    @objc private func absorbingToggled() {
        guard let pins = target?.pins, !pins.isEmpty else { return }
        let absorbing = NSNumber(value: committedCheckboxState(absorbingCheckbox))
        for pin in pins {
            boardSetup?.setAbsorbing(absorbing, forFootprint: pin.reference, pin: pin.number)
        }
        changed()
    }

    /// Applies only what was set to every pin: a mixed checkbox or an empty "<multiple values>"
    /// field leaves each pin's own setting alone.
    @objc private func noiseChanged(_ sender: Any?) {
        guard let pins = target?.pins, !pins.isEmpty, let boardSetup else { return }
        let generating: Bool? = (sender as AnyObject?) === noiseCheckbox ? committedCheckboxState(noiseCheckbox)
            : noiseCheckbox.state == .mixed ? nil : noiseCheckbox.state == .on
        let frequency = (noiseFrequencyField.objectValue as? NSNumber)?.doubleValue
        let amplitude = (noiseAmplitudeField.objectValue as? NSNumber)?.doubleValue
        for pin in pins {
            let setup = boardSetup.pin(withFootprint: pin.reference, pin: pin.number)
            boardSetup.setNoiseGenerating(generating ?? setup?.noiseGenerating ?? false,
                                          frequency: frequency ?? setup?.noiseFrequency ?? defaultNoiseFrequency,
                                          amplitude: amplitude ?? setup?.noiseAmplitude ?? 1,
                                          forFootprint: pin.reference, pin: pin.number)
        }
        changed()
    }

    private func changed() {
        reload()
        onChanged?()
    }

    // MARK: - Net class table

    func numberOfRows(in tableView: NSTableView) -> Int {
        netClassNames.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, netClassNames.indices.contains(row) else { return nil }
        let netClass = netClassNames[row]
        if tableColumn.identifier == Self.nameColumn {
            let identifier = NSUserInterfaceItemIdentifier("BoardSetupNetClassName")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NetNameCellView ?? {
                let view = NetNameCellView()
                view.identifier = identifier
                return view
            }()
            view.configure(name: netClass, font: Self.formFont)
            return view
        }
        let identifier = NSUserInterfaceItemIdentifier("BoardSetupNetClassImpedance")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(string: "")
            field.identifier = identifier
            field.isBordered = false
            field.drawsBackground = false
            field.font = Self.formFont
            field.alignment = .right
            field.formatter = OptionalUnitFormatter(Self.ohmsFormatter())
            field.target = self
            field.action = #selector(tableImpedanceChanged(_:))
            return field
        }()
        field.objectValue = boardSetup?.impedance(forNetClass: netClass)
        field.placeholderString = formattedOhms(boardSetup?.signalImpedance ?? 45)
        return field
    }

    @objc private func tableImpedanceChanged(_ sender: NSTextField) {
        let row = netClassTable.row(for: sender)
        guard netClassNames.indices.contains(row) else { return }
        boardSetup?.setImpedance(sender.objectValue as? NSNumber, forNetClass: netClassNames[row])
        changed()
    }
}
