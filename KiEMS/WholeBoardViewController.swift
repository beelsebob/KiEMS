import Cocoa

/// Shows the whole linked board -- every net's own copper, on every copper layer, at its own real
/// stackup Z, colored per net, plus every footprint's real STEP model -- with GeometryView's same
/// Metal rendering pipeline a simulation's own "Geometry" sub-entry uses, but fed
/// KicadBoardBridge.wholeBoardPreview() instead of a per-simulation sliced/clipped preview (see
/// GeometryPreviewBridge+Private.h's buildWholeBoardPreview() for exactly what's different: nothing
/// here is cut down to any one simulation's involved-nets hull). Fills the *entire* region selecting
/// a simulation itself used to show (see DocumentWindowController.buildUI()) -- replacing the old
/// involved-nets/source-list duo outright, not just InvolvedNetsViewController's old summary-table
/// slot above it. Those classes are still in the project (nothing about their own logic was wrong,
/// and a future net/pin-picking UI may still want them), they're just no longer wired into the
/// visible UI.
///
/// GeometryView's GPU picker reports the selected pin/trace into this controller's right-hand Info
/// column, whose checkboxes edit the currently selected simulation directly. When nothing's
/// selected, that same (narrow, single-field-per-row) column shows `propertiesViewController`'s
/// view instead -- the exact same simulation-wide settings panel (name, ground net, frequency
/// range, via settings, ...) that used to sit permanently above the old source list, reparented
/// here rather than reimplemented (see SimulationPropertiesViewController.labeled()'s own doc
/// comment for its own single-column reflow to actually fit this column's ~240pt width).
final class WholeBoardViewController: NSViewController {
    private static let formFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private weak var document: Document?
    private let propertiesViewController: SimulationPropertiesViewController
    private let boardView = GeometryView()
    private let detailFont = NSFont.systemFont(ofSize: 13)
    private let selectedNetView = NetNameView()
    private let selectedNetClassView = NetNameView()
    private let infoTitle = NSTextField(labelWithString: "Info")
    private let pinHeading = NSTextField(labelWithString: "")
    /// Shown for a selected passive component -- reference is already in pinHeading, this adds its
    /// Value field text, in systemRed when EMSConfigBridge.componentValueIsSensible(_:unit:)
    /// rejects it (matching GeometryView's component-body warning tint).
    private let componentValueLabel = NSTextField(labelWithString: "")
    private let netHeadingPrefix = NSTextField(labelWithString: "Net:")
    private let netClassHeadingPrefix = NSTextField(labelWithString: "Net Class:")
    private let netHeading = NSStackView()
    private let netClassHeading = NSStackView()
    private let pinSeparator = NSBox()
    private let netSeparator = NSBox()
    private let includedCheckbox = NSButton(checkboxWithTitle: "Included in simulation", target: nil, action: nil)
    /// Distinguishes kiems::NetInclusionLevel::SimulationNet from ::GeometryOnly -- see its own doc
    /// comment. `includedCheckbox` alone only means this net's copper is composited into the
    /// simulated geometry (a bystander net, present for coupling/context but not itself part of the
    /// simulation's own signal path); this one promotes it to full participation -- growing the
    /// hull, entering resolvedNets(), and making its pads probe/absorb/excite-eligible.
    private let simulatedCheckbox = NSButton(checkboxWithTitle: "Contribute to Hull", target: nil, action: nil)
    private let impedanceProbedCheckbox = NSButton(checkboxWithTitle: "Impedance Probed", target: nil, action: nil)
    private let netClassIncludedCheckbox = NSButton(checkboxWithTitle: "Included in simulation", target: nil, action: nil)
    private let netClassSimulatedCheckbox = NSButton(checkboxWithTitle: "Contribute to Hull", target: nil, action: nil)
    private let netClassImpedanceProbedCheckbox = NSButton(checkboxWithTitle: "Impedance Probed", target: nil, action: nil)
    private let excitedCheckbox = NSButton(checkboxWithTitle: "Excited", target: nil, action: nil)
    private let mainExcitationCheckbox = NSButton(checkboxWithTitle: "Main Excitation", target: nil, action: nil)
    private let phaseField = NSTextField(string: "")
    private let relativeAmplitudeField = NSTextField(string: "")
    private let frequencyField = NSTextField(string: "")
    private let phaseFormatter = PhaseValueFormatter()
    private let frequencyFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    private let pinImpedanceField = NSTextField(string: "")
    private let pinImpedanceFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Ω", acceptedSuffixes: ["ohms", "ohm", "Ω"])
    private let excitationControls = NSStackView()
    private var frequencyRow: NSStackView!
    private var pinImpedanceRow: NSStackView!
    private let probedCheckbox = NSButton(checkboxWithTitle: "Probed", target: nil, action: nil)
    private let absorbingCheckbox = NSButton(checkboxWithTitle: "Absorbing", target: nil, action: nil)
    private let netControls = NSStackView()
    private let netClassControls = NSStackView()
    private let pinControls = NSStackView()
    private var selection: GeometrySelection?
    private var selectedSimulationIndex: Int?
    private var selectedNetClassName: String?
    private var isLoadingSelectedNetClass = false
    /// Empty values cache a successful "this net has no class" result; absence means not queried.
    private var netClassByNet: [String: String] = [:]
    /// Board-scoped class expansion used by the renderer. Membership comes from libkicad rather
    /// than being inferred from names, and is loaded off the main thread on first use.
    private var netsByNetClass: [String: Set<String>] = [:]
    private var resolvingActivityNetClasses: Set<String> = []
    private struct PinKey: Hashable {
        let simulationIndex: Int
        let reference: String
        let number: String
    }
    /// An Absorbing choice made before the pin is probed/terminated has no persisted port entry yet;
    /// retain that UI preference so it becomes the absorbSignal value if Probe is subsequently set.
    private var pendingAbsorbingChoices: [PinKey: Bool] = [:]

    /// Every footprint on the board, refreshed alongside the whole-board preview (see refresh()) --
    /// needed only to find a differential-pair partner *pin* (same footprint, a
    /// DifferentialPairNetHeuristic-candidate net -- see differentialPairPartnerPin()), the same
    /// board data SourceListViewController's own identically-purposed mirroring logic reads from
    /// allFootprints.
    private var allFootprints: [KicadFootprintInfo] = []

    /// Configuration edits invalidate the same downstream geometry/results state as the retired
    /// source-list editor. DocumentWindowController owns those caches and supplies this callback.
    var onConfigurationChanged: (() -> Void)?

    /// The initial window must not expose selectable simulations or an empty board while the real
    /// KiCad parse/mesh build is still running. DocumentWindowController uses this to replace its
    /// main content with a spinner and reveal the current selection only after loading completes.
    var onLoadingStateChanged: ((Bool) -> Void)?

    /// The kicadPcbPath refresh() last successfully loaded (or attempted for), so repeated calls
    /// from every simulation selection are a cheap no-op until invalidate() is called (the linked
    /// board actually changed on disk -- see DocumentWindowController.handleLinkedKicadFilesChanged)
    /// or a different board gets linked.
    private var loadedForPath: String?
    private var layerGeometryLoader: BoardLayerGeometryLoader?
    private var stitchingViaPlanRevision = 0
    private var plannedStitchingViaPositions: [CGPoint] = []
    private var rejectedStitchingViaPositions: [CGPoint] = []
    private var plannedStitchingViaDiameter: CGFloat = 0

    /// Fixed -- this column stays narrow in every state, net/pin info and simulation settings alike
    /// (propertiesViewController's own layout is a single field-per-row column now, specifically so
    /// it fits here -- see SimulationPropertiesViewController.labeled()'s own doc comment).
    private static let infoPanelWidth: CGFloat = 264

    init(document: Document, propertiesViewController: SimulationPropertiesViewController) {
        self.document = document
        self.propertiesViewController = propertiesViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        boardView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(boardView)

        let infoPanel = NSVisualEffectView()
        infoPanel.material = .sidebar
        infoPanel.blendingMode = .withinWindow
        infoPanel.state = .active
        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(infoPanel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(separator)

        infoTitle.font = .systemFont(ofSize: 16, weight: .semibold)

        selectedNetView.configure(name: "No net selected", font: detailFont)
        selectedNetClassView.configure(name: "Loading…", font: detailFont)

        for heading in [pinHeading, netHeadingPrefix, netClassHeadingPrefix] {
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        componentValueLabel.font = detailFont
        componentValueLabel.isHidden = true
        configureHeadingStack(netHeading, views: [netHeadingPrefix, selectedNetView])
        configureHeadingStack(netClassHeading, views: [netClassHeadingPrefix, selectedNetClassView])
        pinSeparator.boxType = .separator
        netSeparator.boxType = .separator

        configureControlStack(netControls, views: [includedCheckbox, simulatedCheckbox, impedanceProbedCheckbox])
        configureControlStack(netClassControls,
                              views: [netClassIncludedCheckbox, netClassSimulatedCheckbox, netClassImpedanceProbedCheckbox])
        for checkbox in [includedCheckbox, simulatedCheckbox, impedanceProbedCheckbox,
                         netClassIncludedCheckbox, netClassSimulatedCheckbox,
                         netClassImpedanceProbedCheckbox, excitedCheckbox,
                         mainExcitationCheckbox, probedCheckbox, absorbingCheckbox] {
            checkbox.controlSize = .small
            checkbox.font = Self.formFont
        }
        phaseField.formatter = phaseFormatter
        frequencyField.formatter = frequencyFormatter
        relativeAmplitudeField.formatter = Self.numberFormatter
        for field in [phaseField, relativeAmplitudeField, frequencyField] {
            field.controlSize = .small
            field.font = Self.formFont
            field.alignment = .right
            field.target = self
            field.action = #selector(excitationFieldChanged(_:))
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        pinImpedanceField.formatter = pinImpedanceFormatter
        pinImpedanceField.controlSize = .small
        pinImpedanceField.font = Self.formFont
        pinImpedanceField.alignment = .right
        pinImpedanceField.target = self
        pinImpedanceField.action = #selector(pinImpedanceChanged)
        pinImpedanceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mainExcitationCheckbox.target = self
        mainExcitationCheckbox.action = #selector(mainExcitationToggled)
        frequencyRow = excitationValueRow(title: "Frequency:", field: frequencyField)
        let phaseRow = excitationValueRow(title: "Phase:", field: phaseField)
        let relativeAmplitudeRow = excitationValueRow(title: "Relative Amplitude:", field: relativeAmplitudeField)
        configureControlStack(excitationControls, views: [
            mainExcitationCheckbox,
            phaseRow,
            relativeAmplitudeRow,
            frequencyRow,
        ])
        // Everything beneath Excited is a subordinate part of that choice. The 16pt inset makes
        // that hierarchy visible while leaving enough room for the same 92pt-label/90pt-field
        // alignment used by the simulation settings elsewhere in this sidebar.
        excitationControls.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        excitationControls.isHidden = true

        pinImpedanceRow = excitationValueRow(title: "Impedance:", field: pinImpedanceField)
        pinImpedanceRow.edgeInsets = NSEdgeInsets(top: 2, left: 16, bottom: 0, right: 0)

        configureControlStack(pinControls,
                              views: [excitedCheckbox, excitationControls, probedCheckbox, absorbingCheckbox,
                                      pinImpedanceRow])
        includedCheckbox.target = self
        includedCheckbox.action = #selector(includedToggled)
        simulatedCheckbox.target = self
        simulatedCheckbox.action = #selector(simulatedToggled)
        impedanceProbedCheckbox.target = self
        impedanceProbedCheckbox.action = #selector(impedanceProbedToggled)
        netClassIncludedCheckbox.target = self
        netClassIncludedCheckbox.action = #selector(netClassIncludedToggled)
        netClassSimulatedCheckbox.target = self
        netClassSimulatedCheckbox.action = #selector(netClassSimulatedToggled)
        netClassImpedanceProbedCheckbox.target = self
        netClassImpedanceProbedCheckbox.action = #selector(netClassImpedanceProbedToggled)
        excitedCheckbox.target = self
        excitedCheckbox.action = #selector(excitedToggled)
        probedCheckbox.target = self
        probedCheckbox.action = #selector(probedToggled)
        absorbingCheckbox.target = self
        absorbingCheckbox.action = #selector(absorbingToggled)

        let infoStack = NSStackView(views: [infoTitle, pinHeading, componentValueLabel, pinControls, pinSeparator,
                                            netHeading, netControls, netSeparator,
                                            netClassHeading, netClassControls])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 6
        infoStack.setCustomSpacing(16, after: infoTitle)
        infoStack.setCustomSpacing(4, after: pinHeading)
        infoStack.setCustomSpacing(10, after: componentValueLabel)
        infoStack.setCustomSpacing(12, after: pinControls)
        infoStack.setCustomSpacing(10, after: netHeading)
        infoStack.setCustomSpacing(12, after: netControls)
        infoStack.setCustomSpacing(10, after: netClassHeading)
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(infoStack)

        // Shown instead of infoStack whenever nothing's selected on the board -- see
        // updateConfigurationControls(). The exact same instance/state DocumentWindowController
        // itself wires up (name/ground-net/frequency/etc. edits, net-list refreshes on board link) --
        // reparented here, not a second one, so none of that wiring needs duplicating.
        propertiesViewController.view.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.addSubview(propertiesViewController.view)

        boardView.onSelectionChanged = { [weak self] selection in
            guard let self else { return }
            self.selection = selection
            self.selectedNetView.configure(name: selection?.netName ?? "No net selected", font: self.detailFont)
            self.resolveNetClassForSelection()
            self.updateConfigurationControls()
        }

        updateConfigurationControls()

        NSLayoutConstraint.activate([
            boardView.topAnchor.constraint(equalTo: container.topAnchor),
            boardView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            boardView.trailingAnchor.constraint(equalTo: infoPanel.leadingAnchor),
            boardView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            infoPanel.topAnchor.constraint(equalTo: container.topAnchor),
            infoPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            infoPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            infoPanel.widthAnchor.constraint(equalToConstant: Self.infoPanelWidth),

            separator.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor),
            separator.topAnchor.constraint(equalTo: infoPanel.topAnchor),
            separator.bottomAnchor.constraint(equalTo: infoPanel.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            infoStack.topAnchor.constraint(equalTo: infoPanel.topAnchor, constant: 16),
            infoStack.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 10),
            infoStack.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -10),
            pinSeparator.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            netSeparator.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            netHeading.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            netClassHeading.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            // Excitation value rows fill the sidebar from their 16pt subordinate-option indent to
            // the ordinary right content edge. Their text fields have low horizontal hugging, so
            // the recovered width goes to the editable value rather than becoming empty space.
            phaseRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor, constant: -16),
            relativeAmplitudeRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor, constant: -16),
            frequencyRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor, constant: -16),
            pinImpedanceRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor),

            // Below infoStack's own bottom, not infoPanel's top directly -- infoStack's "Info"/
            // "Simulation" title (infoTitle) stays visible even while the rest of infoStack is
            // hidden in settings mode (see updateConfigurationControls()), so anchoring here (rather
            // than to infoPanel.topAnchor, which would start at the same Y as that still-visible
            // title) is what keeps propertiesViewController.view's own first row ("Name") from
            // drawing right on top of it. infoStack collapses to roughly infoTitle's own height once
            // its other children are hidden, so this still sits directly under the title, not with a
            // large gap.
            propertiesViewController.view.topAnchor.constraint(equalTo: infoStack.bottomAnchor, constant: 10),
            propertiesViewController.view.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 10),
            propertiesViewController.view.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -10),
        ])
        view = container
    }

    private func configureControlStack(_ stack: NSStackView, views: [NSView]) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for view in views {
            stack.addArrangedSubview(view)
        }
    }

    private func configureHeadingStack(_ stack: NSStackView, views: [NSView]) {
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 4
        for view in views {
            stack.addArrangedSubview(view)
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        formatter.isLenient = true
        return formatter
    }()

    private func excitationValueRow(title: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = Self.formFont
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 6
        return row
    }

    private var selectedSimulation: EMSSimulationBridge? {
        guard let document, let selectedSimulationIndex,
              document.config.simulations.indices.contains(selectedSimulationIndex)
        else { return nil }
        return document.config.simulations[selectedSimulationIndex]
    }

    private func involvedNetIndex(named name: String, in simulation: EMSSimulationBridge) -> Int? {
        simulation.involvedNets.firstIndex { $0.kind == .net && $0.net == name }
    }

    private func involvedNet(named name: String, in simulation: EMSSimulationBridge) -> EMSInvolvedNetBridge? {
        involvedNetIndex(named: name, in: simulation).map { simulation.involvedNets[$0] }
    }

    private func involvedNetClassIndex(named name: String, in simulation: EMSSimulationBridge) -> Int? {
        simulation.involvedNets.firstIndex { $0.kind == .netClass && $0.netClass == name }
    }

    private func involvedNetClass(named name: String,
                                  in simulation: EMSSimulationBridge) -> EMSInvolvedNetBridge? {
        involvedNetClassIndex(named: name, in: simulation).map { simulation.involvedNets[$0] }
    }

    @discardableResult
    private func includeNet(named name: String, in simulation: EMSSimulationBridge) -> EMSInvolvedNetBridge {
        if let entry = involvedNet(named: name, in: simulation) {
            entry.inclusionLevel = .simulationNet
            return entry
        }
        let entry = simulation.addInvolvedNet(with: .net)
        entry.net = name
        entry.useExplicitPinSelections()
        return entry
    }

    @discardableResult
    private func includeNetClass(named name: String, in simulation: EMSSimulationBridge) -> EMSInvolvedNetBridge {
        if let entry = involvedNetClass(named: name, in: simulation) {
            entry.inclusionLevel = .simulationNet
            return entry
        }
        let entry = simulation.addInvolvedNet(with: .netClass)
        entry.netClass = name
        return entry
    }

    /// The "Included in simulation" checkbox's own minimal effect -- unlike includeNet(), never
    /// forces .simulationNet on an existing entry, and a newly-created one starts at .geometryOnly:
    /// present in the simulated geometry (for coupling/context, e.g. a decoupling cap's other net,
    /// or a plane this net runs over), but not itself part of the simulation (no hull growth, no
    /// resolvedNets() entry, no probe/absorb/excite-eligible pads) until simulatedToggled() (or any
    /// Probe/Excite on one of its pins promotes it through includeNet(); an absorb-only pin remains
    /// valid at GeometryOnly and deliberately uses this helper without promotion.
    @discardableResult
    private func includeNetGeometryOnly(named name: String, in simulation: EMSSimulationBridge) -> EMSInvolvedNetBridge {
        if let entry = involvedNet(named: name, in: simulation) {
            return entry
        }
        let entry = simulation.addInvolvedNet(with: .net)
        entry.net = name
        entry.inclusionLevel = .geometryOnly
        entry.useExplicitPinSelections()
        return entry
    }

    /// See includeNetGeometryOnly's own doc comment -- the net-class equivalent.
    @discardableResult
    private func includeNetClassGeometryOnly(named name: String, in simulation: EMSSimulationBridge) -> EMSInvolvedNetBridge {
        if let entry = involvedNetClass(named: name, in: simulation) {
            return entry
        }
        let entry = simulation.addInvolvedNet(with: .netClass)
        entry.netClass = name
        entry.inclusionLevel = .geometryOnly
        return entry
    }

    /// Resolves the selected net's highest-priority effective KiCad class off the main thread and
    /// caches it for the lifetime of this board preview. Selection can change while the helper is
    /// running, so the UI update is guarded by both board path and current net name.
    private func resolveNetClassForSelection() {
        guard let netName = selection?.netName, !netName.isEmpty,
              let boardPath = document?.config.kicadPcbPath
        else {
            selectedNetClassName = nil
            isLoadingSelectedNetClass = false
            return
        }
        if let cached = netClassByNet[netName] {
            selectedNetClassName = cached.isEmpty ? nil : cached
            isLoadingSelectedNetClass = false
            return
        }

        selectedNetClassName = nil
        isLoadingSelectedNetClass = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = try? KicadBoardBridge.netClass(forNet: netName, board: boardPath)
            DispatchQueue.main.async {
                guard let self, self.loadedForPath == boardPath else { return }
                let value = resolved ?? ""
                self.netClassByNet[netName] = value
                guard self.selection?.netName == netName else { return }
                self.selectedNetClassName = value.isEmpty ? nil : value
                self.isLoadingSelectedNetClass = false
                self.updateConfigurationControls()
            }
        }
    }

    private func excitationIndex(reference: String, pin: String, in simulation: EMSSimulationBridge) -> Int? {
        simulation.excitations.firstIndex { $0.footprintReference == reference && $0.pin == pin }
    }

    private func excitation(reference: String, pin: String, in simulation: EMSSimulationBridge) -> EMSExcitationBridge? {
        excitationIndex(reference: reference, pin: pin, in: simulation).map { simulation.excitations[$0] }
    }

    // MARK: - Differential-pair mirroring
    //
    // Only reachable once the selected simulation is itself explicitly marked as a differential
    // pair (EMSSimulationBridge.isDifferentialPair -- see its own doc comment), so unlike
    // SourceListViewController's identically-purposed (but ask-first, always-on-by-heuristic-alone)
    // offerDifferentialPairMirror family, every mirror here applies immediately, without asking.

    /// The pin on `footprintReference` (if any) matching a differential-pair partner candidate for
    /// `netName`, per DifferentialPairNetHeuristic -- mirrors SourceListViewController's identical
    /// helper (see its own doc comment for why same-footprint is the only correspondence looked
    /// for: a connector/choke/ESD-array part carrying both legs as different pins of one
    /// component, not a pair implemented as two separately-referenced components).
    private func differentialPairPartnerPin(footprintReference: String, netName: String) -> KicadFootprintPin? {
        guard let footprint = allFootprints.first(where: { $0.reference == footprintReference }) else { return nil }
        for candidate in DifferentialPairNetHeuristic.partnerCandidates(for: netName) {
            if let pin = footprint.pins.first(where: { $0.netName == candidate }) {
                return pin
            }
        }
        return nil
    }

    /// A differential-pair partner net name for `netName` that actually exists as some pin's net
    /// on the board, per DifferentialPairNetHeuristic -- mirrors SourceListViewController's
    /// identical net-level lookup.
    private func differentialPairPartnerNetName(for netName: String) -> String? {
        DifferentialPairNetHeuristic.partnerCandidates(for: netName).first { candidate in
            allFootprints.contains { $0.pins.contains { $0.netName == candidate } }
        }
    }

    /// Records reciprocal pair membership on two concrete Net-kind entries -- mirrors
    /// SourceListViewController's identical helper. Newly inferred pairs default to mixed-mode
    /// simulation (simulateAsDifferentialPair); this is what actually makes
    /// port_resolution.cpp's own auto-generation (gated on isDifferentialPair, see
    /// SimulationConfig::isDifferentialPair()'s own doc comment) turn these two nets into a real
    /// diffPairs() entry.
    private func markDifferentialPair(_ firstName: String, _ secondName: String, in simulation: EMSSimulationBridge) {
        guard let first = involvedNet(named: firstName, in: simulation),
              let second = involvedNet(named: secondName, in: simulation)
        else { return }
        first.differentialPairPartner = secondName
        second.differentialPairPartner = firstName
        first.simulateAsDifferentialPair = true
        second.simulateAsDifferentialPair = true
    }

    /// Makes a just-added excitation an ideal odd-mode drive relative to `source` -- mirrors
    /// SourceListViewController's identical helper. Independent FDTD sweeps still use unit
    /// single-port sources; these relative settings are consumed when their responses are
    /// superposed by ExcitationPostprocessor.
    private func configureDifferentialComplement(_ partner: EMSExcitationBridge, from source: EMSExcitationBridge) {
        partner.isMain = source.isMain
        partner.startTime = source.startTime
        partner.duration = source.duration
        partner.frequency = source.frequency
        partner.phaseDegrees = source.phaseDegrees
        partner.amplitude = NSNumber(value: -(source.amplitude?.doubleValue ?? 1.0))
    }

    /// Matches the simulator's auto-discovered lumped parts: an exact, single-letter R/L/C
    /// designator prefix is passive; networks and specialised multi-letter variants are not.
    private func isPassive(reference: String) -> Bool {
        let prefix = String(reference.prefix { $0.isLetter }).uppercased()
        return prefix == "R" || prefix == "L" || prefix == "C"
    }

    private func pinAbsorbsByDefault(reference: String, number: String, netName: String,
                                     in simulation: EMSSimulationBridge) -> Bool {
        guard let pin = allFootprints.first(where: { $0.reference == reference })?.pins
            .first(where: { $0.number == number }),
              pin.pinType == "input" || pin.pinType == "bidirectional" || pin.pinType == "power_in"
        else { return false }
        switch simulation.groundNetKind {
        case .net:
            return simulation.groundNetName != netName
        case .netClass:
            guard let groundClass = simulation.groundNetName else { return true }
            return !(netsByNetClass[groundClass]?.contains(netName) ?? false)
        default:
            return true
        }
    }

    /// Which physical quantity isPassive(reference:)'s own R/L/C prefix implies -- nil for
    /// anything isPassive(reference:) itself would already reject. Used to check the footprint's
    /// Value field with EMSConfigBridge.componentValueIsSensible(_:unit:), the same
    /// parseComponentValue() the simulator's own lumped-component discovery uses.
    private func lumpedComponentUnit(forReference reference: String) -> EMSLumpedComponentUnit? {
        let prefix = String(reference.prefix { $0.isLetter }).uppercased()
        switch prefix {
        case "R": return .resistance
        case "L": return .inductance
        case "C": return .capacitance
        default: return nil
        }
    }

    private func pinKey(reference: String, number: String) -> PinKey? {
        guard let selectedSimulationIndex else { return nil }
        return PinKey(simulationIndex: selectedSimulationIndex, reference: reference, number: number)
    }

    private func updateConfigurationControls() {
        let hasSimulation = selectedSimulation != nil
        includedCheckbox.isEnabled = false
        simulatedCheckbox.isEnabled = false
        impedanceProbedCheckbox.isEnabled = false
        netClassIncludedCheckbox.isEnabled = false
        netClassSimulatedCheckbox.isEnabled = false
        netClassImpedanceProbedCheckbox.isEnabled = false
        excitedCheckbox.isEnabled = false
        mainExcitationCheckbox.isEnabled = false
        probedCheckbox.isEnabled = false
        absorbingCheckbox.isEnabled = false
        pinImpedanceField.isEnabled = false

        includedCheckbox.state = .off
        simulatedCheckbox.state = .off
        impedanceProbedCheckbox.state = .off
        netClassIncludedCheckbox.state = .off
        netClassSimulatedCheckbox.state = .off
        netClassImpedanceProbedCheckbox.state = .off
        excitedCheckbox.state = .off
        mainExcitationCheckbox.state = .off
        excitationControls.isHidden = true
        probedCheckbox.state = .off
        absorbingCheckbox.state = .off
        pinImpedanceField.objectValue = NSNumber(value: 45)

        guard let selection else {
            // Nothing picked on the board -- show this simulation's own settings instead of net/pin
            // info, the same panel (reparented, not reimplemented -- see this class's own doc
            // comment) that used to sit permanently above the old source list.
            infoTitle.stringValue = "Simulation"
            pinHeading.isHidden = true
            pinSeparator.isHidden = true
            netHeading.isHidden = true
            netSeparator.isHidden = true
            netClassHeading.isHidden = true
            netControls.isHidden = true
            netClassControls.isHidden = true
            pinControls.isHidden = true
            componentValueLabel.isHidden = true
            propertiesViewController.view.isHidden = false
            return
        }

        infoTitle.stringValue = "Info"
        propertiesViewController.view.isHidden = true

        // A picked component (see PickTarget.component's own doc comment) has no single net of
        // its own -- a 2-terminal passive bridges two -- so none of the net/net-class sections
        // below apply to it; its own case in the switch below shows just reference + value.
        var isComponentSelection = false
        if case .component = selection.kind {
            isComponentSelection = true
        }
        netHeading.isHidden = isComponentSelection
        netControls.isHidden = isComponentSelection
        netSeparator.isHidden = isComponentSelection
        netClassHeading.isHidden = isComponentSelection
        netClassControls.isHidden = isComponentSelection

        let netName = isComponentSelection ? "" : (selection.netName ?? "")
        guard !isComponentSelection else {
            switch selection.kind {
            case let .component(reference):
                pinHeading.isHidden = false
                pinHeading.stringValue = "Component: \(reference)"
                pinSeparator.isHidden = true
                pinControls.isHidden = true
                if let unit = lumpedComponentUnit(forReference: reference),
                   let footprint = allFootprints.first(where: { $0.reference == reference }) {
                    let value = footprint.value.isEmpty ? "(none)" : footprint.value
                    componentValueLabel.stringValue = "Value: \(value)"
                    componentValueLabel.textColor = EMSConfigBridge.componentValueIsSensible(footprint.value, unit: unit)
                        ? .labelColor : .systemRed
                    componentValueLabel.isHidden = false
                } else {
                    componentValueLabel.isHidden = true
                }
            case .net, .pin:
                break // unreachable -- isComponentSelection is only true for .component
            }
            return
        }
        selectedNetView.configure(name: netName.isEmpty ? "No net" : netName, font: detailFont,
                                  color: netName.isEmpty ? .secondaryLabelColor : .labelColor)
        includedCheckbox.isEnabled = hasSimulation && !netName.isEmpty
        if let simulation = selectedSimulation, !netName.isEmpty,
           let entry = involvedNet(named: netName, in: simulation) {
            let simulated = entry.inclusionLevel == .simulationNet
            includedCheckbox.state = .on
            simulatedCheckbox.state = simulated ? .on : .off
            simulatedCheckbox.isEnabled = true
            impedanceProbedCheckbox.state = entry.probeImpedance ? .on : .off
            impedanceProbedCheckbox.isEnabled = simulated
        }

        let netClassDisplayName: String
        if isLoadingSelectedNetClass {
            netClassDisplayName = "Loading…"
        } else {
            netClassDisplayName = selectedNetClassName ?? "No net class"
        }
        selectedNetClassView.configure(name: netClassDisplayName, font: detailFont,
                                       color: selectedNetClassName == nil ? .secondaryLabelColor : .labelColor)
        if let simulation = selectedSimulation, let netClassName = selectedNetClassName,
           !netClassName.isEmpty {
            netClassIncludedCheckbox.isEnabled = true
            if let entry = involvedNetClass(named: netClassName, in: simulation) {
                let simulated = entry.inclusionLevel == .simulationNet
                netClassIncludedCheckbox.state = .on
                netClassSimulatedCheckbox.state = simulated ? .on : .off
                netClassSimulatedCheckbox.isEnabled = true
                netClassImpedanceProbedCheckbox.state = entry.probeImpedance ? .on : .off
                netClassImpedanceProbedCheckbox.isEnabled = simulated
            }
        }

        switch selection.kind {
        case .net:
            pinHeading.isHidden = true
            pinSeparator.isHidden = true
            pinControls.isHidden = true
            componentValueLabel.isHidden = true

        case .component:
            break // handled above, before isComponentSelection's early return

        case let .pin(reference, number):
            pinHeading.isHidden = false
            pinHeading.stringValue = "Pin: \(reference)/\(number)"
            pinSeparator.isHidden = false
            pinControls.isHidden = false
            // Every isPassive(reference:) pin/pad now selects as .component instead (see
            // PickTarget's own doc comment) -- a .pin selection here is always a non-passive
            // (connector/IC) pin, so there's never a sensible component value to show for it.
            componentValueLabel.isHidden = true
            let hasNet = !netName.isEmpty
            excitedCheckbox.isEnabled = hasSimulation && hasNet
            probedCheckbox.isEnabled = hasSimulation && hasNet
            absorbingCheckbox.isEnabled = hasSimulation && hasNet
            pinImpedanceField.isEnabled = hasSimulation && hasNet
            guard let simulation = selectedSimulation else { return }
            // This mirrors the resolver's real default termination rule; unlike the previous
            // appearance-only fallback, every checked default here corresponds to a 45-ohm port
            // the simulation builder will actually create.
            let defaultAbsorbing = pinKey(reference: reference, number: number)
                .flatMap { pendingAbsorbingChoices[$0] } ??
                pinAbsorbsByDefault(reference: reference, number: number, netName: netName, in: simulation)
            absorbingCheckbox.state = defaultAbsorbing ? .on : .off
            if let excitation = excitation(reference: reference, pin: number, in: simulation) {
                excitedCheckbox.state = .on
                // Excitations always resolve to an absorbing port, irrespective of the per-pin
                // Probe/Absorbing entry.
                absorbingCheckbox.state = .on
                excitationControls.isHidden = false
                mainExcitationCheckbox.isEnabled = true
                mainExcitationCheckbox.state = excitation.isMain ? .on : .off
                phaseField.doubleValue = excitation.phaseDegrees
                relativeAmplitudeField.objectValue = excitation.amplitude ?? NSNumber(value: 1)
                frequencyField.objectValue = excitation.frequency ?? NSNumber(value: document?.config.frequencyStart ?? 0)
                frequencyRow.isHidden = excitation.isMain
            }
            guard !netName.isEmpty, let entry = involvedNet(named: netName, in: simulation)
            else { return }
            pinImpedanceField.objectValue = entry.impedance(withFootprint: reference, pin: number)
                ?? NSNumber(value: entry.impedance)
            if entry.hasExplicitPinSelections {
                let probed = entry.isPinProbed(withFootprint: reference, pin: number)
                probedCheckbox.state = probed ? .on : .off
                let absorbing: Bool
                if probed {
                    absorbing = entry.pinAbsorbsSignal(withFootprint: reference, pin: number)
                } else if let configured = entry.probedPins.first(where: {
                    $0.footprintReference == reference && $0.pin == number
                }) {
                    // probe=false entries retain both sides of the explicit Absorbing choice; a
                    // false value must remain visibly off after reload.
                    absorbing = configured.absorbSignal
                } else if let key = pinKey(reference: reference, number: number),
                          let pending = pendingAbsorbingChoices[key] {
                    absorbing = pending
                } else {
                    absorbing = pinAbsorbsByDefault(reference: reference, number: number,
                                                    netName: netName, in: simulation)
                }
                absorbingCheckbox.state = absorbing ? .on : .off
            } else {
                // Preserve the effective state of old files until this pin is edited; legacy net
                // entries implicitly probed every non-excluded pin and always absorbed it, but
                // only when the entry is actually Simulated. GeometryOnly entries create no
                // implicit ports.
                let probed = entry.inclusionLevel == .simulationNet &&
                    !entry.isPinExcluded(withFootprint: reference, pin: number)
                probedCheckbox.state = probed ? .on : .off
                let absorbs = probed || pinAbsorbsByDefault(reference: reference, number: number,
                                                            netName: netName, in: simulation)
                absorbingCheckbox.state = absorbs ? .on : .off
            }
            // The resolver gives a driven pin an absorbing port even when an explicit per-pin
            // entry says otherwise. Keep the displayed effective state subject to the same final
            // precedence rule.
            if excitation(reference: reference, pin: number, in: simulation) != nil {
                absorbingCheckbox.state = .on
            }
        }
    }

    private func configurationChanged() {
        document?.updateChangeCount(.changeDone)
        updateConfigurationControls()
        refreshActivityHighlight()
        onConfigurationChanged?()
    }

    /// Every included net (subtle flash) and, among those, every real excitation and passive
    /// bridge (ripple) for the currently selected simulation -- pushed to boardView.activity
    /// whenever that config, or the board's own footprint/pin data (allFootprints), changes. See
    /// BoardActivityHighlight's own doc comment for why this only ever supplies names/identities,
    /// never positions -- GeometryView resolves those from its own already-built pick geometry.
    private func computeActivityHighlight() -> BoardActivityHighlight {
        guard let simulation = selectedSimulation else { return BoardActivityHighlight() }
        var highlight = BoardActivityHighlight()
        highlight.hasSelectedSimulation = true
        highlight.hullPadding = simulation.hullPadding
        highlight.plannedStitchingViaPositions = plannedStitchingViaPositions
        highlight.rejectedStitchingViaPositions = rejectedStitchingViaPositions
        highlight.plannedStitchingViaDiameter = plannedStitchingViaDiameter
        var groundNets = Set<String>()
        if simulation.groundNetKind == .net,
           let groundNetName = simulation.groundNetName, !groundNetName.isEmpty {
            groundNets.insert(groundNetName)
            highlight.fullySaturatedNets.insert(groundNetName)
        } else if simulation.groundNetKind == .netClass,
                  let groundNetClass = simulation.groundNetName,
                  let members = netsByNetClass[groundNetClass] {
            groundNets.formUnion(members)
            highlight.fullySaturatedNets.formUnion(members)
        }
        for entry in simulation.involvedNets {
            let memberNets: Set<String>
            switch entry.kind {
            case .net:
                guard let netName = entry.net, !netName.isEmpty else { continue }
                memberNets = [netName]
            case .netClass:
                guard let netClass = entry.netClass, !netClass.isEmpty,
                      let resolvedMembers = netsByNetClass[netClass]
                else { continue }
                memberNets = resolvedMembers
            default:
                continue
            }
            highlight.configurationIncludedNets.formUnion(memberNets)
            if entry.inclusionLevel == .simulationNet {
                highlight.includedNets.formUnion(memberNets)
            }
        }
        // The setup preview uses the same rule as board_slicing.cpp: every full simulation net,
        // not merely nets carrying a main excitation, expands the padded cutout.
        highlight.hullExpandingNets = highlight.includedNets
        var footprintByReference: [String: KicadFootprintInfo] = [:]
        for footprint in allFootprints {
            footprintByReference[footprint.reference] = footprint
        }
        for excitation in simulation.excitations {
            guard let footprint = footprintByReference[excitation.footprintReference],
                  let pin = footprint.pins.first(where: { $0.number == excitation.pin }), !pin.netName.isEmpty
            else { continue }
            highlight.excitedPins.append(BoardActivityHighlight.ExcitedPin(
                reference: excitation.footprintReference, padNumber: excitation.pin, netName: pin.netName))
        }
        // Resolve the exact same effective Probe/Absorb state as port_resolution.cpp. In
        // particular, GeometryOnly entries do *not* inherit legacy "every pin is a probe" behavior:
        // they can contribute only an explicitly configured absorb-only pin. This distinction is
        // important for broad geometry-only net classes, which otherwise painted every matching
        // component pin as a blue/yellow port even though the real simulation created no such port.
        struct PinKey: Hashable { let reference: String, number: String, net: String }
        var probedPins = Set<PinKey>()
        var absorbingPins = Set<PinKey>()
        var explicitAbsorbingState: [PinKey: Bool] = [:]
        for entry in simulation.involvedNets {
            if entry.inclusionLevel == .geometryOnly {
                // Mirrors port_resolution.cpp's separate GeometryOnly pass: ignore legacy defaults
                // and reportable probes, accepting only explicit probe=false, absorb=true entries.
                guard entry.hasExplicitPinSelections else { continue }
                for pin in entry.probedPins where !pin.probe {
                    let netName = footprintByReference[pin.footprintReference]?.pins
                        .first(where: { $0.number == pin.pin })?.netName ?? entry.net ?? ""
                    guard !netName.isEmpty else { continue }
                    let key = PinKey(reference: pin.footprintReference, number: pin.pin, net: netName)
                    explicitAbsorbingState[key] = pin.absorbSignal
                    if pin.absorbSignal {
                        absorbingPins.insert(key)
                    }
                }
                continue
            }
            if entry.hasExplicitPinSelections {
                for pin in entry.probedPins {
                    let netName = footprintByReference[pin.footprintReference]?.pins
                        .first(where: { $0.number == pin.pin })?.netName ?? entry.net ?? ""
                    guard !netName.isEmpty else { continue }
                    let key = PinKey(reference: pin.footprintReference, number: pin.pin, net: netName)
                    if pin.probe {
                        probedPins.insert(key)
                    }
                    // If overlapping selectors describe the same pin, any real absorbing port wins.
                    explicitAbsorbingState[key] = (explicitAbsorbingState[key] ?? false) || pin.absorbSignal
                    if pin.absorbSignal {
                        absorbingPins.insert(key)
                    }
                }
            } else {
                let memberNets: Set<String>
                switch entry.kind {
                case .net:
                    memberNets = entry.net.map { Set([$0]) } ?? []
                case .netClass:
                    memberNets = entry.netClass.flatMap { netsByNetClass[$0] } ?? []
                default:
                    memberNets = []
                }
                for footprint in allFootprints {
                    for pin in footprint.pins where memberNets.contains(pin.netName) {
                        let key = PinKey(reference: footprint.reference, number: pin.number, net: pin.netName)
                        let enabled = !entry.isPinExcluded(withFootprint: footprint.reference, pin: pin.number)
                        if enabled {
                            // Legacy entries implicitly probe and absorb every non-excluded pin.
                            probedPins.insert(key)
                            absorbingPins.insert(key)
                            explicitAbsorbingState[key] = true
                        } else if explicitAbsorbingState[key] == nil {
                            explicitAbsorbingState[key] = false
                        }
                    }
                }
            }
        }
        let excitedPinKeys = Set(highlight.excitedPins.map {
            PinKey(reference: $0.reference, number: $0.padNumber, net: $0.netName)
        })
        for footprint in allFootprints {
            // Absorb-only ports are valid on GeometryOnly entries too, so use the full configured
            // inclusion set here rather than the narrower Simulated/animated-net set.
            for pin in footprint.pins where highlight.configurationIncludedNets.contains(pin.netName) {
                let key = PinKey(reference: footprint.reference, number: pin.number, net: pin.netName)
                if excitedPinKeys.contains(key) {
                    // The resolver always gives an excitation a full absorbing port.
                    absorbingPins.insert(key)
                } else if let explicit = explicitAbsorbingState[key] {
                    if explicit { absorbingPins.insert(key) }
                } else if let pendingKey = pinKey(reference: footprint.reference, number: pin.number),
                          let pending = pendingAbsorbingChoices[pendingKey] {
                    if pending { absorbingPins.insert(key) }
                } else if (pin.pinType == "input" || pin.pinType == "bidirectional" ||
                           pin.pinType == "power_in") && !groundNets.contains(pin.netName) {
                    // Same default the simulation builder turns into a real 45-ohm port.
                    absorbingPins.insert(key)
                }
            }
        }
        highlight.probedPins = probedPins
            .sorted {
                ($0.reference, $0.number, $0.net) < ($1.reference, $1.number, $1.net)
            }
            .map { BoardActivityHighlight.ProbedPin(reference: $0.reference,
                                                     padNumber: $0.number, netName: $0.net) }
        highlight.absorbingPins = absorbingPins
            .sorted {
                ($0.reference, $0.number, $0.net) < ($1.reference, $1.number, $1.net)
            }
            .map { BoardActivityHighlight.AbsorbingPin(reference: $0.reference,
                                                        padNumber: $0.number, netName: $0.net) }
        // Component appearance follows electrical involvement, not whether the body happened to
        // be named explicitly in configuration. This also catches every pin of a multi-pin part
        // whose net was selected at either inclusion level.
        for footprint in allFootprints where footprint.pins.contains(where: {
            highlight.configurationIncludedNets.contains($0.netName)
        }) {
            highlight.involvedComponentReferences.insert(footprint.reference)
        }
        for pin in highlight.excitedPins {
            highlight.involvedComponentReferences.insert(pin.reference)
        }
        for pin in highlight.probedPins {
            highlight.involvedComponentReferences.insert(pin.reference)
        }
        for pin in highlight.absorbingPins {
            highlight.involvedComponentReferences.insert(pin.reference)
        }
        for entry in simulation.involvedNets where entry.hasExplicitPinSelections {
            for pin in entry.probedPins {
                highlight.involvedComponentReferences.insert(pin.footprintReference)
            }
        }
        // Match port_resolution.cpp's lumped-component discovery: both terminals must belong to
        // copper included at either level, with the selected ground net(s) also eligible. This
        // includes series passives between GeometryOnly nets and shunt parts jumping from any
        // included net to ground, without pulling unrelated passives elsewhere on the PCB into the
        // activity graph.
        let passiveEligibleNets = highlight.configurationIncludedNets.union(groundNets)
        for footprint in allFootprints where footprint.pins.count == 2 && isPassive(reference: footprint.reference) {
            let first = footprint.pins[0]
            let second = footprint.pins[1]
            guard !first.netName.isEmpty, !second.netName.isEmpty, first.netName != second.netName,
                  passiveEligibleNets.contains(first.netName), passiveEligibleNets.contains(second.netName)
            else { continue }
            highlight.passiveBridges.append(BoardActivityHighlight.PassiveBridge(
                reference: footprint.reference, firstPad: first.number, firstNet: first.netName,
                secondPad: second.number, secondNet: second.netName))
            if let unit = lumpedComponentUnit(forReference: footprint.reference),
               !EMSConfigBridge.componentValueIsSensible(footprint.value, unit: unit) {
                highlight.invalidComponentReferences.insert(footprint.reference)
            }
        }
        return highlight
    }

    /// Not private -- also called from DocumentWindowController's own propertiesVC.
    /// onGeometryParametersChanged wiring: hull padding changes the fast region highlight, while
    /// padding/inset/spacing all change the asynchronously recomputed stitching-via plan.
    /// propertiesViewController is always editing whichever simulation is currently selected here
    /// (it's the same embedded selection, see this class's own top comment), so there's no index to
    /// check against -- this always recomputes for selectedSimulationIndex, which is already correct.
    func refreshActivityHighlight() {
        resolveActivityNetClassesIfNeeded()
        boardView.activity = computeActivityHighlight()
        refreshStitchingViaPlan()
    }

    /// Runs the same slicing/via-placement code as Geometry without publishing or caching a
    /// Geometry stage. A revision token prevents an older worker result replacing a newer edit.
    private func refreshStitchingViaPlan() {
        stitchingViaPlanRevision += 1
        let revision = stitchingViaPlanRevision
        plannedStitchingViaPositions = []
        rejectedStitchingViaPositions = []
        plannedStitchingViaDiameter = 0
        guard let document, let selectedSimulationIndex,
              let boardPath = document.config.kicadPcbPath,
              loadedForPath == boardPath, boardView.preview != nil,
              let request = KicadBoardBridge.stitchingViaPlanRequest(
                forConfig: document.config, simulationIndex: selectedSimulationIndex)
        else {
            boardView.activity = computeActivityHighlight()
            return
        }
        boardView.activity = computeActivityHighlight()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = try? request.compute(forBoard: boardPath)
            DispatchQueue.main.async {
                guard let self, self.stitchingViaPlanRevision == revision,
                      self.loadedForPath == boardPath,
                      self.selectedSimulationIndex == selectedSimulationIndex else { return }
                self.plannedStitchingViaPositions = plan?.placedPositions.map(\.pointValue) ?? []
                self.rejectedStitchingViaPositions = plan?.rejectedPositions.map(\.pointValue) ?? []
                self.plannedStitchingViaDiameter = CGFloat(plan?.annularRingDiameter ?? 0)
                self.boardView.activity = self.computeActivityHighlight()
            }
        }
    }

    /// Expands every selected net-class entry once per loaded board. The immediate highlight uses
    /// any cached classes; each newly completed query refreshes it, so neither board loading nor a
    /// checkbox edit blocks the UI on board parsing.
    private func resolveActivityNetClassesIfNeeded() {
        guard let simulation = selectedSimulation,
              let boardPath = document?.config.kicadPcbPath else { return }
        var requiredClasses = Set(simulation.involvedNets.compactMap { entry -> String? in
            guard entry.kind == .netClass, let name = entry.netClass, !name.isEmpty else { return nil }
            return name
        })
        if simulation.groundNetKind == .netClass,
           let groundClass = simulation.groundNetName, !groundClass.isEmpty {
            requiredClasses.insert(groundClass)
        }
        for netClass in requiredClasses
            where netsByNetClass[netClass] == nil && !resolvingActivityNetClasses.contains(netClass) {
            resolvingActivityNetClasses.insert(netClass)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let members = (try? KicadBoardBridge.netsInNetClass(
                    forBoard: boardPath, netClass: netClass)) ?? []
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.resolvingActivityNetClasses.remove(netClass)
                    guard self.loadedForPath == boardPath else { return }
                    self.netsByNetClass[netClass] = Set(members)
                    self.boardView.activity = self.computeActivityHighlight()
                }
            }
        }
    }

    private func applyNetIncluded(_ included: Bool, netName: String, in simulation: EMSSimulationBridge) {
        if included {
            includeNetGeometryOnly(named: netName, in: simulation)
        } else if let index = involvedNetIndex(named: netName, in: simulation) {
            simulation.removeInvolvedNet(at: index)
        }
    }

    @objc private func includedToggled() {
        guard let netName = selection?.netName, !netName.isEmpty, let simulation = selectedSimulation
        else { return }
        let included = includedCheckbox.state == .on
        applyNetIncluded(included, netName: netName, in: simulation)
        if simulation.isDifferentialPair, let partnerNetName = differentialPairPartnerNetName(for: netName),
           (involvedNet(named: partnerNetName, in: simulation) != nil) != included {
            applyNetIncluded(included, netName: partnerNetName, in: simulation)
            if included {
                markDifferentialPair(netName, partnerNetName, in: simulation)
            }
        }
        configurationChanged()
    }

    /// See simulatedCheckbox's own doc comment. Unlike includedToggled(), this never removes the
    /// entry -- turning "Contribute to Hull" off just demotes it back to .geometryOnly (the net's
    /// own copper stays in the simulated geometry either way; only whether it's a full participant
    /// changes).
    @objc private func simulatedToggled() {
        guard let netName = selection?.netName, !netName.isEmpty, let simulation = selectedSimulation,
              let entry = involvedNet(named: netName, in: simulation)
        else { return }
        if simulatedCheckbox.state == .on {
            includeNet(named: netName, in: simulation)
        } else {
            entry.inclusionLevel = .geometryOnly
        }
        configurationChanged()
    }

    @objc private func impedanceProbedToggled() {
        guard let netName = selection?.netName, !netName.isEmpty,
              let simulation = selectedSimulation, let entry = involvedNet(named: netName, in: simulation)
        else { return }
        entry.probeImpedance = impedanceProbedCheckbox.state == .on
        configurationChanged()
    }

    @objc private func netClassIncludedToggled() {
        guard let netClassName = selectedNetClassName, !netClassName.isEmpty,
              let simulation = selectedSimulation
        else { return }
        if netClassIncludedCheckbox.state == .on {
            includeNetClassGeometryOnly(named: netClassName, in: simulation)
        } else if let index = involvedNetClassIndex(named: netClassName, in: simulation) {
            simulation.removeInvolvedNet(at: index)
        }
        configurationChanged()
    }

    /// See simulatedCheckbox's own doc comment -- the net-class equivalent.
    @objc private func netClassSimulatedToggled() {
        guard let netClassName = selectedNetClassName, !netClassName.isEmpty,
              let simulation = selectedSimulation,
              let entry = involvedNetClass(named: netClassName, in: simulation)
        else { return }
        if netClassSimulatedCheckbox.state == .on {
            includeNetClass(named: netClassName, in: simulation)
        } else {
            entry.inclusionLevel = .geometryOnly
        }
        configurationChanged()
    }

    @objc private func netClassImpedanceProbedToggled() {
        guard let netClassName = selectedNetClassName, !netClassName.isEmpty,
              let simulation = selectedSimulation,
              let entry = involvedNetClass(named: netClassName, in: simulation)
        else { return }
        entry.probeImpedance = netClassImpedanceProbedCheckbox.state == .on
        configurationChanged()
    }

    private func applyExcited(_ excited: Bool, footprintReference: String, netName: String, padNumber: String,
                               in simulation: EMSSimulationBridge) {
        if excited {
            includeNet(named: netName, in: simulation)
            if excitationIndex(reference: footprintReference, pin: padNumber, in: simulation) == nil {
                let excitation = simulation.addExcitation(forFootprint: footprintReference, pin: padNumber)
                // The normal case is a broadband drive using the simulation's sweep. A user can
                // uncheck Main Excitation to reveal and configure a narrowband frequency instead.
                excitation.isMain = true
                excitation.phaseDegrees = 0
                excitation.amplitude = NSNumber(value: 1)
            }
        } else if let index = excitationIndex(reference: footprintReference, pin: padNumber, in: simulation) {
            simulation.removeExcitation(at: index)
        }
    }

    @objc private func excitedToggled() {
        guard case let .pin(reference, number)? = selection?.kind, let netName = selection?.netName,
              let simulation = selectedSimulation
        else { return }
        let excited = excitedCheckbox.state == .on
        applyExcited(excited, footprintReference: reference, netName: netName, padNumber: number, in: simulation)
        if simulation.isDifferentialPair,
           let partner = differentialPairPartnerPin(footprintReference: reference, netName: netName),
           partner.number != number {
            let wasExcited = excitationIndex(reference: reference, pin: partner.number, in: simulation) != nil
            if wasExcited != excited {
                applyExcited(excited, footprintReference: reference, netName: partner.netName,
                             padNumber: partner.number, in: simulation)
                if excited {
                    if let source = excitation(reference: reference, pin: number, in: simulation),
                       let mirrored = excitation(reference: reference, pin: partner.number, in: simulation) {
                        configureDifferentialComplement(mirrored, from: source)
                    }
                    markDifferentialPair(netName, partner.netName, in: simulation)
                }
            }
        }
        configurationChanged()
    }

    @objc private func mainExcitationToggled() {
        guard case let .pin(reference, number)? = selection?.kind,
              let simulation = selectedSimulation,
              let excitation = excitation(reference: reference, pin: number, in: simulation)
        else { return }
        excitation.isMain = mainExcitationCheckbox.state == .on
        if !excitation.isMain {
            if excitation.frequency == nil || excitation.frequency?.doubleValue == 0 {
                excitation.frequency = NSNumber(value: document?.config.frequencyStart ?? 0)
            }
            if excitation.amplitude == nil {
                excitation.amplitude = NSNumber(value: 1)
            }
        }
        synchronizeDifferentialExcitation(from: excitation, reference: reference, pin: number)
        configurationChanged()
    }

    @objc private func excitationFieldChanged(_ sender: NSTextField) {
        guard case let .pin(reference, number)? = selection?.kind,
              let simulation = selectedSimulation,
              let excitation = excitation(reference: reference, pin: number, in: simulation)
        else { return }
        switch sender {
        case phaseField:
            excitation.phaseDegrees = sender.doubleValue
        case relativeAmplitudeField:
            excitation.amplitude = NSNumber(value: sender.doubleValue)
        case frequencyField:
            excitation.frequency = NSNumber(value: sender.doubleValue)
        default:
            return
        }
        synchronizeDifferentialExcitation(from: excitation, reference: reference, pin: number)
        configurationChanged()
    }

    private func synchronizeDifferentialExcitation(from source: EMSExcitationBridge,
                                                    reference: String, pin: String) {
        guard let simulation = selectedSimulation, simulation.isDifferentialPair,
              let netName = selection?.netName,
              let partnerPin = differentialPairPartnerPin(footprintReference: reference, netName: netName),
              partnerPin.number != pin,
              let partner = excitation(reference: reference, pin: partnerPin.number, in: simulation)
        else { return }
        configureDifferentialComplement(partner, from: source)
    }

    @discardableResult
    private func applyProbed(_ probed: Bool, absorbing: Bool, footprintReference: String, netName: String,
                              padNumber: String, in simulation: EMSSimulationBridge) -> Bool {
        let entry = probed ? includeNet(named: netName, in: simulation)
                           : involvedNet(named: netName, in: simulation)
        guard let entry else { return false }
        if probed {
            entry.setPinProbed(true, absorbSignal: absorbing, withFootprint: footprintReference, pin: padNumber)
        } else if absorbing {
            entry.setPinAbsorbOnly(true, withFootprint: footprintReference, pin: padNumber)
        } else {
            entry.setPinAbsorbOnly(false, withFootprint: footprintReference, pin: padNumber)
        }
        return true
    }

    @objc private func probedToggled() {
        guard case let .pin(reference, number)? = selection?.kind, let netName = selection?.netName,
              let simulation = selectedSimulation
        else { return }
        let probed = probedCheckbox.state == .on
        let absorbing = absorbingCheckbox.state == .on
        guard applyProbed(probed, absorbing: absorbing, footprintReference: reference, netName: netName,
                          padNumber: number, in: simulation)
        else { return }
        if simulation.isDifferentialPair,
           let partner = differentialPairPartnerPin(footprintReference: reference, netName: netName),
           partner.number != number {
            applyProbed(probed, absorbing: absorbing, footprintReference: reference, netName: partner.netName,
                       padNumber: partner.number, in: simulation)
            if probed {
                markDifferentialPair(netName, partner.netName, in: simulation)
            }
        }
        configurationChanged()
    }

    @discardableResult
    private func applyAbsorbing(_ absorbing: Bool, probed: Bool, footprintReference: String, netName: String,
                                 padNumber: String, in simulation: EMSSimulationBridge) -> Bool {
        if probed {
            let entry = includeNet(named: netName, in: simulation)
            entry.setPinProbed(true, absorbSignal: absorbing, withFootprint: footprintReference, pin: padNumber)
            return true
        } else if absorbing {
            // A termination needs its copper present, but does not make the net a simulated signal
            // path. Preserve an existing level, or create the minimal GeometryOnly entry.
            let entry = includeNetGeometryOnly(named: netName, in: simulation)
            entry.setPinAbsorbOnly(true, withFootprint: footprintReference, pin: padNumber)
            return true
        } else {
            // Persist the negative choice too. Without an entry, reloading would fall back to the
            // UI's default-on absorbing state for active components and the blue marker returned.
            let entry = includeNetGeometryOnly(named: netName, in: simulation)
            entry.setPinAbsorbOnly(false, withFootprint: footprintReference, pin: padNumber)
            return true
        }
    }

    @objc private func absorbingToggled() {
        guard case let .pin(reference, number)? = selection?.kind, let netName = selection?.netName,
              let simulation = selectedSimulation
        else { return }
        let absorbing = absorbingCheckbox.state == .on
        if let key = pinKey(reference: reference, number: number) {
            pendingAbsorbingChoices[key] = absorbing
        }
        let probed = probedCheckbox.state == .on
        var changedConfiguration = applyAbsorbing(absorbing, probed: probed, footprintReference: reference,
                                                    netName: netName, padNumber: number, in: simulation)
        if simulation.isDifferentialPair,
           let partner = differentialPairPartnerPin(footprintReference: reference, netName: netName),
           partner.number != number {
            let changedPartner = applyAbsorbing(absorbing, probed: probed, footprintReference: reference,
                                                 netName: partner.netName, padNumber: partner.number, in: simulation)
            if changedPartner {
                markDifferentialPair(netName, partner.netName, in: simulation)
                changedConfiguration = true
            }
        }
        if changedConfiguration {
            configurationChanged()
        } else {
            updateConfigurationControls()
            // A not-yet-persisted default override still changes the effective marker immediately.
            refreshActivityHighlight()
        }
    }

    @objc private func pinImpedanceChanged() {
        guard case let .pin(reference, number)? = selection?.kind,
              let netName = selection?.netName, !netName.isEmpty,
              let simulation = selectedSimulation
        else { return }
        let value = max(0, pinImpedanceField.doubleValue)
        pinImpedanceField.doubleValue = value
        let entry = includeNetGeometryOnly(named: netName, in: simulation)
        entry.setImpedance(NSNumber(value: value), withFootprint: reference, pin: number)
        configurationChanged()
    }

    func setSelectedSimulationIndex(_ index: Int?) {
        selectedSimulationIndex = index
        updateConfigurationControls()
        refreshActivityHighlight()
    }

    /// Loads (or re-shows the already-loaded) whole-board preview for whichever board is currently
    /// linked. Cheap to call on every simulation selection, board-file change notification, etc. --
    /// only actually re-queries the board the first time it's called for a given kicadPcbPath, or
    /// after invalidate() clears that memory.
    @discardableResult
    func refresh() -> Bool {
        guard let document, let kicadPcbPath = document.config.kicadPcbPath else { return false }
        guard loadedForPath != kicadPcbPath else { return false }
        loadedForPath = kicadPcbPath
        layerGeometryLoader?.cancel()
        layerGeometryLoader = nil
        onLoadingStateChanged?(true)
        // Publish the cheap KiCad layer catalog first. The visible setup layers are then generated
        // first; every other layer trickles in behind them without holding the screen hostage.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let catalog = try? KicadBoardBridge.layerCatalogPreview(
                forBoard: kicadPcbPath, wholeBoard: true)
            DispatchQueue.main.async {
                guard let self, self.loadedForPath == kicadPcbPath else { return }
                guard let catalog else { self.onLoadingStateChanged?(false); return }
                self.boardView.preview = catalog
                let visible = ["F.Cu", "F.Adhesive", "F.Adhes", "F.Mask", "F.Fab", "Edge.Cuts"]
                let loader = BoardLayerGeometryLoader(boardPath: kicadPcbPath, preview: catalog,
                                                       view: self.boardView, initiallyVisible: visible,
                                                       generateAll: false) { [weak self] in
                    self?.loadWholeBoardDetails(for: kicadPcbPath, catalog: catalog)
                }
                self.layerGeometryLoader = loader
                self.onLoadingStateChanged?(false)
                loader.start()
                self.refreshStitchingViaPlan()
            }
        }
        return true
    }

    /// Runs only after the initially-visible layer meshes have landed. Keeping this behind that
    /// small priority batch both bounds concurrent KiCad board loads and prevents the old detailed
    /// preview path from delaying the layers the user can actually see.
    private func loadWholeBoardDetails(for kicadPcbPath: String, catalog: EMSGeometryPreview) {
        layerGeometryLoader?.cancel()
        layerGeometryLoader = nil
        boardView.onLayerNeedsGeometry = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let detailed = try? KicadBoardBridge.wholeBoardPreview(forBoard: kicadPcbPath)
            let footprints = (try? KicadBoardBridge.footprints(forBoard: kicadPcbPath)) ?? []
            DispatchQueue.main.async {
                guard let self, self.loadedForPath == kicadPcbPath else { return }
                self.allFootprints = footprints
                self.refreshActivityHighlight()
                if let detailed, let preview = self.boardView.preview {
                    preview.mergeLoadedPreview(detailed)
                    self.boardView.refreshLoadedGeometry()
                }
                let loader = BoardLayerGeometryLoader(boardPath: kicadPcbPath, preview: catalog,
                                                       view: self.boardView,
                                                       initiallyVisible: self.boardView.visibleLayerNames)
                self.layerGeometryLoader = loader
                loader.start()
            }
        }
    }

    /// Forces the next refresh() call to actually re-query the board, rather than treating it as
    /// already loaded -- see DocumentWindowController.handleLinkedKicadFilesChanged.
    func invalidate() {
        layerGeometryLoader?.cancel()
        layerGeometryLoader = nil
        loadedForPath = nil
        netClassByNet.removeAll()
        netsByNetClass.removeAll()
        resolvingActivityNetClasses.removeAll()
        selectedNetClassName = nil
        isLoadingSelectedNetClass = false
    }
}
