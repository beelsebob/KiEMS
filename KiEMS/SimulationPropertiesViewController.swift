import Cocoa

/// The "simulation-wide properties" panel: name, ground net, frequency range, via
/// settings. Edits whichever simulation SimulationListViewController has selected (see
/// setSelectedSimulationIndex) -- viaPlatingThickness/viaFillingEpsilon/frequencyStart/frequencyStop
/// stay editable regardless (they're document-level, not per-simulation), but the rest disable
/// themselves when nothing is selected. For a Simulation Set template it shows only the Geometry
/// and Resolution sections, below SimulationSetViewController, and its edits reach the generated
/// simulations through the same callbacks (see DocumentWindowController).
final class SimulationPropertiesViewController: NSViewController {
    /// The Info panel chooses which part of this controller is visible.  Keeping the controls in
    /// one controller means the Tests tab continues to edit the same simulation and notifications
    /// as the Simulation tab.
    enum DisplaySection {
        case simulation
        case tests
    }
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
    /// those affect the FDTD run itself, not the geometry step's own output. The String is a short,
    /// user-facing description of what changed, listed in the results' "out of date" banner.
    var onGeometryParametersChanged: ((Int, String) -> Void)?

    /// Fired whenever maxStepsField, the frequency range or the via plating/filling fields change -- unlike onGeometryParametersChanged, this doesn't
    /// affect geometry at all (it's a pure FDTD-run setting, document-level like frequency/via
    /// plating above it), so it only needs to invalidate simulation *results*, and for every
    /// simulation in the document at once (maxSteps isn't per-simulation). Too low a value truncates
    /// the FDTD run before its energy has decayed, which is exactly the bug this field exists to let
    /// the user fix -- so a stale cached result from before raising it would defeat the point.
    /// The String is a short, user-facing description of what changed -- see onGeometryParametersChanged.
    var onFDTDParametersChanged: ((String) -> Void)?
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
    private let edgeTerminationList = NetListEditorView()
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
    // The vacuum between the board and the absorbing boundary in X/Y -- document-level and
    // geometry-changing like gridDensityField. Its tooltip carries the quarter-wavelength suggestion.
    private let marginWidthField = NSTextField(string: "")
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
    // Per-simulation: the pulse window of every main excitation in the selected simulation (each
    // ExcitationConfig carries its own duration; this sets them all at once). Shows "Mixed" as a
    // placeholder if they've been given different values individually in the source list.
    private let excitationDurationField = NSTextField(string: "")
    private let eyeDrawCountField = NSTextField(string: "")
    private let sharedClockCheckbox = NSButton(checkboxWithTitle: "Adversarial Signals Share a Clock",
                                               target: nil, action: nil)

    // Length fields each get their own formatter instance -- the displayed/accepted unit is
    // per-instance state (see MicrometerValueFormatter), so sharing one across fields would make
    // them all switch units together whenever any single field's unit changed.
    private let gridDensityFormatter = MicrometerValueFormatter()
    private let marginWidthFormatter = MicrometerValueFormatter()
    private let viaEdgeDistanceFormatter = MicrometerValueFormatter()
    private let viaSpacingFormatter = MicrometerValueFormatter()
    private let platingThicknessFormatter = MicrometerValueFormatter()
    private let frequencyStartFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    private let frequencyStopFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    private let excitationDurationFormatter = UnitSuffixValueFormatter(
        displaySuffix: "s", acceptedSuffixes: ["seconds", "second", "secs", "sec", "s"],
        autoSelectsSIPrefix: true)
    private let maxStepsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0 // Timesteps are a plain integer count, never fractional.
        return formatter
    }()

    /// Draws are split across 8 independently randomized replicates (see kiems::EyeNoiseOptions),
    /// so fewer than 8 isn't meaningful. The cap keeps the results preview (built on the main
    /// thread) responsive: 1024 draws cost roughly a third of a second per eye.
    private let eyeDrawCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 8
        formatter.maximum = 1024
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

    // The eye mask, bit rate and signal level every eye in the results is built and tested with.
    private lazy var eyeTestSection = EyeTestSectionView { [unowned self] title, control in
        self.labeled(title, control)
    }

    private var groundNetClassNames: [String] = []
    private var groundNetNames: [String] = []
    private var simulationSettingsStack: NSStackView?
    private var testsStack: NSStackView?
    // Hidden for a Simulation Set template: it's named in the sidebar, and shows only the
    // Geometry and Resolution sections its generated simulations share.
    private var nameRow: NSView?
    private var networksSection: NSView?


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
        let label = NSTextField(labelWithString: title.hasSuffix(":") ? String(title.dropLast()) : title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .white
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

    /// Like labeled(), but with the title above the control rather than beside it, and the control
    /// spanning the panel's full width -- for lists, which are too cramped next to a label column.
    private func stacked(_ title: String, _ control: NSView) -> NSStackView {
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

    private func section(_ title: String, views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let section = NSStackView(views: [heading] + views)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        section.setCustomSpacing(8, after: heading)
        heading.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        for view in views {
            view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    private func buildUI() {
        sharedClockCheckbox.target = self
        sharedClockCheckbox.action = #selector(sharedClockToggled)
        sharedClockCheckbox.controlSize = .small
        sharedClockCheckbox.font = Self.formFont
        differentialPairCheckbox.target = self
        differentialPairCheckbox.action = #selector(differentialPairToggled)
        differentialPairCheckbox.controlSize = .small
        differentialPairCheckbox.font = Self.formFont

        nameField.target = self
        nameField.action = #selector(nameChanged)

        groundNameComboBox.onCommit = { [weak self] name, tag in self?.groundNameChanged(name, tag: tag) }
        edgeTerminationList.onChange = { [weak self] rows in self?.commitEdgeTerminatedNets(rows) }
        groundNameComboBox.controlSize = .small
        groundNameComboBox.font = Self.formFont

        viaEdgeDistanceField.formatter = viaEdgeDistanceFormatter
        viaSpacingField.formatter = viaSpacingFormatter
        platingThicknessField.formatter = platingThicknessFormatter
        fillingEpsilonField.formatter = Self.plainNumberFormatter
        frequencyStartField.formatter = frequencyStartFormatter
        frequencyStopField.formatter = frequencyStopFormatter
        excitationDurationField.formatter = excitationDurationFormatter
        eyeDrawCountField.formatter = eyeDrawCountFormatter
        maxStepsField.formatter = maxStepsFormatter
        gridDensityField.formatter = gridDensityFormatter
        absorbingBoundaryField.formatter = absorbingBoundaryFormatter
        marginWidthField.formatter = marginWidthFormatter

        for field in [viaEdgeDistanceField, viaSpacingField, platingThicknessField,
                      fillingEpsilonField, frequencyStartField, frequencyStopField, maxStepsField,
                      gridDensityField, absorbingBoundaryField, marginWidthField, excitationDurationField,
                      eyeDrawCountField] {
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
                stacked("Edge Terminated Nets:", edgeTerminationList),
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
                labeled("Margin Width:", marginWidthField),
                labeled("Timestep Length:", maxTimestepValueLabel),
                labeled("Max Timesteps:", maxStepsField),
                labeled("Sim Real Time:", simulationRealTimeValueLabel),
                labeled("Frequency Range:", frequencyRange),
                labeled("Excitation Duration:", excitationDurationField),
                labeled("Adversarial Draws:", eyeDrawCountField),
                labeled("", sharedClockCheckbox),
            ])
        eyeTestSection.onChange = { [weak self] in
            guard let self else { return }
            self.document?.updateChangeCount(.changeDone)
            if let selectedIndex = self.selectedIndex {
                self.onResultsParametersChanged?(selectedIndex)
            }
        }
        self.nameRow = nameRow
        self.networksSection = networksSection
        let simulationViews = [nameRow, networksSection, geometrySection, resolutionSection]
        let simulationStack = NSStackView(views: simulationViews)
        simulationStack.orientation = .vertical
        simulationStack.alignment = .leading
        simulationStack.spacing = 14
        simulationStack.translatesAutoresizingMaskIntoConstraints = false
        for view in simulationViews {
            view.widthAnchor.constraint(equalTo: simulationStack.widthAnchor).isActive = true
        }
        simulationSettingsStack = simulationStack

        let tests = NSStackView(views: [eyeTestSection])
        tests.orientation = .vertical
        tests.alignment = .leading
        tests.translatesAutoresizingMaskIntoConstraints = false
        eyeTestSection.widthAnchor.constraint(equalTo: tests.widthAnchor).isActive = true
        testsStack = tests
        tests.isHidden = true

        // An outer stack gives this view a fitting height for whichever tab is visible. Hidden
        // arranged subviews are removed from that calculation, avoiding a Tests panel that keeps
        // the much taller Simulation panel's empty space.
        let content = NSStackView(views: [simulationStack, tests])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        simulationStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        tests.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    func setDisplaySection(_ section: DisplaySection) {
        simulationSettingsStack?.isHidden = section == .tests
        testsStack?.isHidden = section == .simulation
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
            onGeometryParametersChanged?(selectedIndex, "Ground or edge-terminated nets changed")
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
        marginWidthField.doubleValue = document.config.marginWidth
        updateDerivedTimingLabels()
        updateMarginWidthToolTip()

        let isSimulationSet = selectedSimulation?.simulationSet != nil
        nameRow?.isHidden = isSimulationSet
        networksSection?.isHidden = isSimulationSet

        guard let sim = selectedSimulation else {
            nameField.stringValue = ""
            viaEdgeDistanceField.stringValue = ""
            viaSpacingField.stringValue = ""
            excitationDurationField.stringValue = ""
            excitationDurationField.placeholderString = nil
            eyeTestSection.simulation = nil
            eyeDrawCountField.stringValue = ""
            sharedClockCheckbox.state = .off
            differentialPairCheckbox.state = .off
            groundNameComboBox.entries = []
            groundNameComboBox.stringValue = ""
            edgeTerminationList.rows = []
            setPerSimulationFieldsEnabled(false)
            return
        }
        setPerSimulationFieldsEnabled(true)

        nameField.stringValue = sim.name
        differentialPairCheckbox.state = sim.isDifferentialPair ? .on : .off
        viaEdgeDistanceField.doubleValue = sim.viaEdgeDistance
        viaSpacingField.doubleValue = sim.viaSpacing
        reloadExcitationDuration(for: sim)
        eyeTestSection.simulation = sim
        eyeDrawCountField.integerValue = sim.eyeDrawCount
        sharedClockCheckbox.state = sim.adversarialSharedClock ? .on : .off
        edgeTerminationList.rows = sim.edgeTerminatedNets

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

    /// Called after the source list adds, removes or edits an excitation, so the main-excitation
    /// duration shown here doesn't go stale.
    func excitationsEditedElsewhere() {
        guard let sim = selectedSimulation else { return }
        reloadExcitationDuration(for: sim)
    }

    /// A Simulation Set template has no excitation of its own: it shows the main excitations of the
    /// simulations generated from it, and an edit sets the set's own duration for them (see
    /// EMSSimulationSetBridge.excitationDuration).
    private func reloadExcitationDuration(for sim: EMSSimulationBridge) {
        let mainExcitations: [EMSExcitationBridge]
        if let identifier = sim.simulationSet?.identifier, let document {
            mainExcitations = document.config.simulations
                .filter { $0.generatedBySetIdentifier == identifier }
                .flatMap { $0.excitations.filter(\.isMain) }
        } else {
            mainExcitations = sim.excitations.filter(\.isMain)
        }
        let durations = mainExcitations.map(\.duration)
        excitationDurationField.isEnabled = !durations.isEmpty
        if let first = durations.first, durations.allSatisfy({ $0 == first }) {
            excitationDurationField.doubleValue = first
            excitationDurationField.placeholderString = nil
        } else {
            excitationDurationField.stringValue = ""
            excitationDurationField.placeholderString = durations.isEmpty ? "No main excitation" : "Mixed"
        }
    }

    private func setPerSimulationFieldsEnabled(_ enabled: Bool) {
        for control in [nameField, differentialPairCheckbox, groundNameComboBox,
                         viaEdgeDistanceField, viaSpacingField, eyeDrawCountField,
                         sharedClockCheckbox] as [NSControl] {
            control.isEnabled = enabled
        }
        edgeTerminationList.isEditable = enabled
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
                self?.edgeTerminationList.availableNames = NetNameFormatting.sortedForDisplay(nets)
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
    /// Eye post-analysis only, like the bit rate -- no FDTD data goes stale.
    @objc private func sharedClockToggled() {
        guard let sim = selectedSimulation else { return }
        sim.adversarialSharedClock = sharedClockCheckbox.state == .on
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onResultsParametersChanged?(selectedIndex)
        }
    }

    @objc private func differentialPairToggled() {
        guard let sim = selectedSimulation else { return }
        sim.isDifferentialPair = differentialPairCheckbox.state == .on
        if sim.isDifferentialPair {
            onDifferentialPairEnabled?(sim)
        }
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex, "Differential pair setting changed")
        }
    }

    private func applyGroundSelection(_ name: String?, to sim: EMSSimulationBridge) {
        sim.groundNetName = name
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex, "Ground net changed")
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
            onGeometryParametersChanged?(selectedIndex, "Ground net changed")
        }
        updateGroundNameComboBox()
    }

    /// Edge terminations are part of the sliced geometry (SlicedBoard::edgeTerminationLoops), so
    /// any change invalidates this simulation's cached geometry like a ground-net change does.
    private func commitEdgeTerminatedNets(_ rows: [String]) {
        guard let sim = selectedSimulation else { return }
        sim.edgeTerminatedNets = rows
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex, "Edge-terminated nets changed")
        }
    }

    @objc private func numberFieldChanged(_ sender: NSTextField) {
        guard let document else { return }
        var affectsGeometry = false
        var affectsAllGeometry = false
        var affectsFDTD = false
        var affectsResults = false
        var reason = ""
        switch sender {
        case viaEdgeDistanceField:
            reason = "Via stitching changed"
            selectedSimulation?.viaEdgeDistance = sender.doubleValue
            affectsGeometry = true
        case viaSpacingField:
            reason = "Via stitching changed"
            selectedSimulation?.viaSpacing = sender.doubleValue
            affectsGeometry = true
        case excitationDurationField:
            // Only the postprocessed stimulus (see ExcitationPostprocessor) uses a main
            // excitation's duration, so this invalidates results, not the FDTD run.
            if let sim = selectedSimulation, let set = sim.simulationSet {
                set.excitationDuration = NSNumber(value: sender.doubleValue)
                sim.simulationSet = set
            } else {
                for excitation in selectedSimulation?.excitations ?? [] where excitation.isMain {
                    excitation.duration = sender.doubleValue
                }
            }
            affectsResults = true
        case eyeDrawCountField:
            selectedSimulation?.eyeDrawCount = sender.integerValue
            affectsResults = true
        // Document-level FDTD-run settings, like maxSteps: the sweep range sets the frequencies the
        // ports transform to, and the via plating/filling set the materials the run uses -- none of
        // them change the geometry step's output, but every simulation's results go stale.
        case platingThicknessField:
            reason = "Via materials changed"
            document.config.viaPlatingThickness = sender.doubleValue
            affectsFDTD = true
        case fillingEpsilonField:
            reason = "Via materials changed"
            document.config.viaFillingEpsilon = sender.doubleValue
            affectsFDTD = true
        case frequencyStartField:
            reason = "Frequency range changed"
            document.config.frequencyStart = sender.doubleValue
            affectsFDTD = true
        case frequencyStopField:
            reason = "Frequency range changed"
            document.config.frequencyStop = sender.doubleValue
            affectsFDTD = true
        case maxStepsField:
            reason = "Maximum timesteps changed"
            document.config.maxSteps = sender.integerValue
            affectsFDTD = true
        case gridDensityField:
            reason = "Grid density changed"
            // Document-level, like maxSteps, but unlike maxSteps it genuinely changes the Grid
            // pipeline stage's own output (mesh line placement) -- every simulation's cached
            // geometry needs invalidating, not just whichever one happens to be selected right now.
            document.config.gridDensity = sender.doubleValue
            affectsAllGeometry = true
        case absorbingBoundaryField:
            reason = "Absorbing boundary changed"
            // Document-level and geometry-changing, exactly like gridDensityField.
            document.config.absorbingBoundaryCells = sender.integerValue
            affectsAllGeometry = true
        case marginWidthField:
            reason = "Margin width changed"
            // Document-level and geometry-changing, exactly like gridDensityField.
            document.config.marginWidth = max(0, sender.doubleValue)
            sender.doubleValue = document.config.marginWidth
            affectsAllGeometry = true
        default: break
        }
        document.updateChangeCount(.changeDone)
        if affectsAllGeometry {
            // A Simulation Set template never runs, and its generated simulations are among these.
            for (index, simulation) in document.config.simulations.enumerated() where simulation.simulationSet == nil {
                onGeometryParametersChanged?(index, reason)
            }
        } else if affectsGeometry, let selectedIndex {
            onGeometryParametersChanged?(selectedIndex, reason)
        }
        if affectsFDTD {
            onFDTDParametersChanged?(reason)
        }
        if affectsResults, let selectedIndex {
            onResultsParametersChanged?(selectedIndex)
        }
        updateDerivedTimingLabels()
        updateMarginWidthToolTip()
    }

    /// The margin's rule-of-thumb value -- a quarter of the vacuum wavelength at the start frequency
    /// -- offered as a suggestion only: for a board's signal integrity the absorber only needs to
    /// clear the fringing fields, so a few millimetres is usually enough.
    private func updateMarginWidthToolTip() {
        let base = "Vacuum between the board and the absorbing boundary in X and Y."
        guard let suggested = document?.config.suggestedMarginWidth, suggested > 0,
              let text = marginWidthFormatter.string(for: suggested) else {
            marginWidthField.toolTip = base
            return
        }
        marginWidthField.toolTip = base + " A quarter of the vacuum wavelength at the start frequency would be \(text)."
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
