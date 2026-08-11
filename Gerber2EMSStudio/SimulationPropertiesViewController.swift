import Cocoa

/// The "simulation-wide properties" panel: name, ground net, hull padding, frequency range, via
/// settings. Edits whichever simulation SimulationListViewController has selected (see
/// setSelectedSimulationIndex) -- viaPlatingThickness/viaFillingEpsilon/frequencyStart/frequencyStop
/// stay editable regardless (they're document-level, not per-simulation), but the rest disable
/// themselves when nothing is selected.
final class SimulationPropertiesViewController: NSViewController {
    private weak var document: Document?
    private var selectedIndex: Int?

    /// Fired whenever the selected simulation's name changes (see nameChanged) --
    /// DocumentWindowController wires this to SimulationListViewController.refreshRows(), which has
    /// no other way to learn that the row it's showing for this simulation is now stale.
    var onNameChanged: (() -> Void)?

    /// Fired (with the changed simulation's index) whenever a field that affects the *shape* of the
    /// geometry step's output changes -- hull padding, via edge distance/spacing, or the ground net
    /// itself. DocumentWindowController wires this to GeometryViewController.invalidateCache(
    /// forSimulationIndex:), so a stale cached geometry/error from before the edit doesn't keep
    /// being shown. Deliberately not fired for platingThickness/fillingEpsilon/frequency fields --
    /// those affect the FDTD run itself, not the geometry step's own output.
    var onGeometryParametersChanged: ((Int) -> Void)?

    private let nameField = NSTextField(string: "")
    private let groundKindPopUp = NSPopUpButton()
    private let groundNamePopUp = NSPopUpButton()
    private let hullPaddingField = NSTextField(string: "")
    private let viaEdgeDistanceField = NSTextField(string: "")
    private let viaSpacingField = NSTextField(string: "")
    private let platingThicknessField = NSTextField(string: "")
    private let fillingEpsilonField = NSTextField(string: "")
    // The FDTD frequency sweep range -- document-level (EMSConfig), not per-simulation, same as
    // platingThicknessField/fillingEpsilonField, so these stay enabled/populated regardless of
    // whether a simulation is selected (see reload()/setPerSimulationFieldsEnabled()).
    private let frequencyStartField = NSTextField(string: "")
    private let frequencyStopField = NSTextField(string: "")

    // Length fields each get their own formatter instance -- the displayed/accepted unit is
    // per-instance state (see MicrometerValueFormatter), so sharing one across fields would make
    // them all switch units together whenever any single field's unit changed.
    private let hullPaddingFormatter = MicrometerValueFormatter()
    private let viaEdgeDistanceFormatter = MicrometerValueFormatter()
    private let viaSpacingFormatter = MicrometerValueFormatter()
    private let platingThicknessFormatter = MicrometerValueFormatter()
    private let frequencyStartFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    private let frequencyStopFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)

    private let viaAdvancedDisclosureButton = NSButton()
    private var viaAdvancedRow: NSStackView?
    private var viaAdvancedRowExpanded = false

    private var groundNetClassNames: [String] = []
    private var groundNetNames: [String] = []

    // What the user had selected the last time the ground-net kind was the *other* one -- restored
    // verbatim on switching back (see groundKindChanged), rather than re-guessing every time. Reset
    // whenever the selected simulation changes, so one simulation's choices never leak into another's.
    private var rememberedNetName: String?
    private var rememberedNetClassName: String?

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

    private func labeled(_ title: String, _ control: NSView, labelWidth: CGFloat = 120) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func buildUI() {
        nameField.target = self
        nameField.action = #selector(nameChanged)

        groundKindPopUp.addItems(withTitles: ["Net", "Net Class"])
        groundKindPopUp.target = self
        groundKindPopUp.action = #selector(groundKindChanged)

        groundNamePopUp.target = self
        groundNamePopUp.action = #selector(groundNameChanged)

        hullPaddingField.formatter = hullPaddingFormatter
        viaEdgeDistanceField.formatter = viaEdgeDistanceFormatter
        viaSpacingField.formatter = viaSpacingFormatter
        platingThicknessField.formatter = platingThicknessFormatter
        fillingEpsilonField.formatter = Self.plainNumberFormatter
        frequencyStartField.formatter = frequencyStartFormatter
        frequencyStopField.formatter = frequencyStopFormatter

        for field in [hullPaddingField, viaEdgeDistanceField, viaSpacingField, platingThicknessField,
                      fillingEpsilonField, frequencyStartField, frequencyStopField] {
            field.alignment = .right
            field.target = self
            field.action = #selector(numberFieldChanged(_:))
        }

        viaAdvancedDisclosureButton.bezelStyle = .regularSquare
        viaAdvancedDisclosureButton.isBordered = false
        viaAdvancedDisclosureButton.imagePosition = .imageOnly
        viaAdvancedDisclosureButton.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: "Show more via settings")
        viaAdvancedDisclosureButton.target = self
        viaAdvancedDisclosureButton.action = #selector(toggleViaAdvancedRow)
        viaAdvancedDisclosureButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        viaAdvancedDisclosureButton.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let groundRow = NSStackView(views: [groundKindPopUp, groundNamePopUp])
        groundRow.orientation = .horizontal
        groundRow.spacing = 8

        let frequencyStartRow = labeled("Frequency start:", frequencyStartField, labelWidth: 130)
        // 130, not a tighter fit for "Stop:" -- matches viaSpacing's/fillingEpsilon's second-column
        // labelWidth below so "Stop"/"Via spacing"/"Via filling epsilon" line up as one column.
        let frequencyStopRow = labeled("Stop:", frequencyStopField, labelWidth: 130)
        // frequencyRow (a stack-of-stacks, unlike the single-level rows above it e.g. nameField's)
        // doesn't hug its content tightly against the outer `stack`'s required-priority pin to
        // view's edges -- .fill distribution stretches an arranged subview to absorb the leftover
        // width regardless of that subview's own hugging priority. Same fix as viaMainRowSpacer
        // below: give the spare width somewhere invisible to go, at the row's end, instead of
        // letting it open a gap between "Frequency start" and "Stop".
        let frequencyRowSpacer = NSView()
        frequencyRowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let frequencyRow = NSStackView(views: [frequencyStartRow, frequencyStopRow, frequencyRowSpacer])
        frequencyRow.orientation = .horizontal
        frequencyRow.spacing = 8

        // Absorbs all the row's spare width, so "Via edge distance"/"Via spacing" stay snugly
        // adjacent regardless of how wide the row ends up -- only the disclosure button (pinned
        // after this spacer) moves when the row's overall width changes, never the fields before it.
        let viaMainRowSpacer = NSView()
        viaMainRowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let viaMainRow = NSStackView(views: [
            labeled("Via edge distance:", viaEdgeDistanceField, labelWidth: 130),
            // 130, not a tighter fit -- see frequencyStopRow's comment above.
            labeled("Via spacing:", viaSpacingField, labelWidth: 130),
            viaMainRowSpacer,
            viaAdvancedDisclosureButton,
        ])
        viaMainRow.orientation = .horizontal
        viaMainRow.spacing = 8

        let viaAdvancedRow = NSStackView(views: [
            labeled("Via plating thickness:", platingThicknessField, labelWidth: 130),
            labeled("Via filling epsilon:", fillingEpsilonField, labelWidth: 130),
        ])
        viaAdvancedRow.orientation = .horizontal
        viaAdvancedRow.spacing = 8
        viaAdvancedRow.isHidden = true
        self.viaAdvancedRow = viaAdvancedRow

        let stack = NSStackView(views: [
            // labelWidth 130 on all three (not the 120 default) so their fields line up with Via
            // edge distance's field directly below -- "Via edge distance:" is the widest label here.
            labeled("Name:", nameField, labelWidth: 130),
            labeled("Ground net:", groundRow, labelWidth: 130),
            labeled("Hull padding:", hullPaddingField, labelWidth: 130),
            frequencyRow,
            viaMainRow,
            viaAdvancedRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        // Pinned to all four edges, not just leading/top -- view (a plain NSView with no intrinsic
        // content size of its own) needs its size fully determined by stack's, or it collapses to
        // zero when arranged as a subview inside DocumentWindowController's outer NSStackView. The
        // bluish-grey background strip behind this panel now lives in DocumentWindowController
        // instead (spanning the full window width, not just this column) -- see propertiesBackgroundStrip.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        for field in [nameField, hullPaddingField] {
            field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        // Same 100pt for every field in this panel, frequencyStart/Stop included -- keeps "Via
        // spacing"/"Stop"/"Via filling epsilon" (all labelWidth 130 above) lined up as one column.
        for field in [viaEdgeDistanceField, viaSpacingField, platingThicknessField, fillingEpsilonField,
                      frequencyStartField, frequencyStopField] {
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }
        // Forces viaMainRow to span stack's full width -- otherwise it would just be as wide as its
        // own tightly-packed content, and the disclosure button (the row's last item) wouldn't reach
        // the panel's true right edge until the wider rows above happened to make stack wider anyway.
        // Only valid once both share a common ancestor (stack, just added above as their shared
        // ancestor's descendant) -- activating this before that doesn't fail cleanly, it hangs.
        NSLayoutConstraint.activate([
            viaMainRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            viaMainRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    private static let plainNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    @objc private func toggleViaAdvancedRow() {
        viaAdvancedRowExpanded.toggle()
        viaAdvancedRow?.isHidden = !viaAdvancedRowExpanded
        viaAdvancedDisclosureButton.image = NSImage(
            systemSymbolName: viaAdvancedRowExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: "Show more via settings")
    }

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
        rememberedNetName = nil
        rememberedNetClassName = nil
        reload()
    }

    /// Called by SimulationListViewController (via DocumentWindowController) after a rename
    /// performed directly in the source list -- if this panel happens to be showing that same
    /// simulation right now, its own name field would otherwise go stale. Deliberately just the one
    /// field, not a full setSelectedSimulationIndex(_:) re-call: that also resets
    /// rememberedNetName/rememberedNetClassName and re-queries net lists, neither of which a plain
    /// rename should disturb.
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

        guard let sim = selectedSimulation else {
            nameField.stringValue = ""
            hullPaddingField.stringValue = ""
            viaEdgeDistanceField.stringValue = ""
            viaSpacingField.stringValue = ""
            groundNamePopUp.removeAllItems()
            setPerSimulationFieldsEnabled(false)
            return
        }
        setPerSimulationFieldsEnabled(true)

        nameField.stringValue = sim.name
        groundKindPopUp.selectItem(at: sim.groundNetKind == .net ? 0 : 1)
        hullPaddingField.doubleValue = sim.hullPadding
        viaEdgeDistanceField.doubleValue = sim.viaEdgeDistance
        viaSpacingField.doubleValue = sim.viaSpacing

        refreshNetLists()

        // A brand-new simulation (added via SimulationListViewController's + button, as opposed to
        // the board's first, auto-created one -- see DocumentWindowController.importSucceeded, which
        // already guesses for that case) has no real ground net choice yet -- EMSConfigBridge's
        // addSimulationNamed: sets it to an empty string, not nil (to_json() dereferences the active
        // kind's optional unconditionally, so it can never be left unset -- see that method's own
        // comment), so isEmpty is the right check here, not == nil. Left alone,
        // updateGroundNamePopUp() below has nothing to select() for an empty name, so the popup just
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
        for control in [nameField, groundKindPopUp, groundNamePopUp, hullPaddingField, viaEdgeDistanceField,
                         viaSpacingField] as [NSControl] {
            control.isEnabled = enabled
        }
    }

    /// Called after a KiCad board is linked (see DocumentWindowController) -- the ground-net
    /// popup's choices depend on the board that was just linked.
    func refreshNetLists() {
        guard let document, let kicadPcbPath = document.config.kicadPcbPath else { return }
        let helperPath = AppPaths.kicadQueryHelperPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let classes = (try? KicadBoardBridge.netClasses(forBoard: kicadPcbPath,
                                                              kicadQueryHelperPath: helperPath)) ?? []
            let nets = (try? KicadBoardBridge.allNets(forBoard: kicadPcbPath,
                                                        kicadQueryHelperPath: helperPath)) ?? []
            DispatchQueue.main.async {
                self?.groundNetClassNames = classes
                self?.groundNetNames = nets
                self?.updateGroundNamePopUp()
            }
        }
    }

    private func updateGroundNamePopUp() {
        guard let sim = selectedSimulation else { return }
        let names = sim.groundNetKind == .net ? groundNetNames : groundNetClassNames
        groundNamePopUp.removeAllItems()
        // Built as NSMenuItems directly (rather than addItems(withTitles:)) so each can carry an
        // attributedTitle -- NSPopUpButton draws its own button face from the selected item's
        // attributedTitle when set, so this renders sub/superscript on the button itself, not just
        // in the dropdown.
        let font = groundNamePopUp.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        for name in names {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.attributedTitle = NetNameFormatting.attributedString(for: name, font: font)
            groundNamePopUp.menu?.addItem(item)
        }
        if let currentName = sim.groundNetName, let index = names.firstIndex(of: currentName) {
            groundNamePopUp.selectItem(at: index)
        }
    }

    @objc private func nameChanged() {
        selectedSimulation?.name = nameField.stringValue
        document?.updateChangeCount(.changeDone)
        onNameChanged?()
    }

    @objc private func groundKindChanged() {
        guard let sim = selectedSimulation else { return }
        let newKind: EMSGroundSelectorKind = groundKindPopUp.indexOfSelectedItem == 0 ? .net : .netClass
        let previousKind = sim.groundNetKind
        guard newKind != previousKind else { return }
        let previousName = sim.groundNetName

        // Remember whatever was active before switching away from it, so switching back restores it
        // exactly rather than re-guessing.
        if previousKind == .net {
            rememberedNetName = previousName
        } else {
            rememberedNetClassName = previousName
        }

        sim.groundNetKind = newKind
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
        // Refresh the popup's item list immediately (selecting nothing yet, since sim.groundNetName
        // is still the old kind's value) -- resolveNewGroundSelection corrects the selection once it
        // has an answer, synchronously or, when it needs a fresh net-class-membership query, async.
        updateGroundNamePopUp()

        resolveNewGroundSelection(for: sim, newKind: newKind, previousKind: previousKind, previousName: previousName)
    }

    /// Picks what to select after switching ground-net kind, per (in priority order): a remembered
    /// choice from the last time this kind was active; otherwise a guess derived from whatever was
    /// just active in the *other* kind (a net class containing the previous net, or the best-guess
    /// ground net within the previous net class); otherwise a fresh best-guess over everything.
    private func resolveNewGroundSelection(for sim: EMSSimulationBridge, newKind: EMSGroundSelectorKind,
                                             previousKind: EMSGroundSelectorKind, previousName: String?) {
        if newKind == .net {
            if let remembered = rememberedNetName, groundNetNames.contains(remembered) {
                applyGroundSelection(remembered, to: sim)
            } else if previousKind == .netClass, let netClassName = previousName {
                guessNet(within: netClassName, for: sim)
            } else {
                applyGroundSelection(GroundNetHeuristic.bestGuess(among: groundNetNames), to: sim)
            }
        } else {
            if let remembered = rememberedNetClassName, groundNetClassNames.contains(remembered) {
                applyGroundSelection(remembered, to: sim)
            } else if previousKind == .net, let netName = previousName {
                guessNetClass(containing: netName, for: sim)
            } else {
                applyGroundSelection(GroundNetHeuristic.bestGuess(among: groundNetClassNames), to: sim)
            }
        }
    }

    private func applyGroundSelection(_ name: String?, to sim: EMSSimulationBridge) {
        sim.groundNetName = name
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
        updateGroundNamePopUp()
    }

    /// Finds the best-guess ground net among netClassName's own members, querying the board for its
    /// membership since that isn't cached anywhere (unlike groundNetNames/groundNetClassNames).
    private func guessNet(within netClassName: String, for sim: EMSSimulationBridge) {
        guard let document, let kicadPcbPath = document.config.kicadPcbPath else {
            applyGroundSelection(GroundNetHeuristic.bestGuess(among: groundNetNames), to: sim)
            return
        }
        let helperPath = AppPaths.kicadQueryHelperPath
        let targetIndex = selectedIndex
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let members = (try? KicadBoardBridge.netsInNetClass(
                forBoard: kicadPcbPath, netClass: netClassName, kicadQueryHelperPath: helperPath)) ?? []
            let guess = GroundNetHeuristic.bestGuess(among: members) ?? members.first
            DispatchQueue.main.async {
                // The user may have selected a different simulation while this query was in flight --
                // don't apply a guess computed for the wrong one.
                guard let self, self.selectedIndex == targetIndex, let currentSim = self.selectedSimulation else {
                    return
                }
                self.applyGroundSelection(guess, to: currentSim)
            }
        }
    }

    /// Finds a net class that contains netName by querying each net class's own membership in turn --
    /// there's no direct "which net class is this net in" query, only the reverse. Falls back to the
    /// most ground-like net class name if none actually contains it (a net not assigned any class, or
    /// a stale remembered name, say).
    private func guessNetClass(containing netName: String, for sim: EMSSimulationBridge) {
        guard let document, let kicadPcbPath = document.config.kicadPcbPath else {
            applyGroundSelection(GroundNetHeuristic.bestGuess(among: groundNetClassNames), to: sim)
            return
        }
        let helperPath = AppPaths.kicadQueryHelperPath
        let netClasses = groundNetClassNames
        let targetIndex = selectedIndex
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var containingClass: String?
            for netClass in netClasses {
                let members = (try? KicadBoardBridge.netsInNetClass(
                    forBoard: kicadPcbPath, netClass: netClass, kicadQueryHelperPath: helperPath)) ?? []
                if members.contains(netName) {
                    containingClass = netClass
                    break
                }
            }
            let guess = containingClass ?? GroundNetHeuristic.bestGuess(among: netClasses)
            DispatchQueue.main.async {
                guard let self, self.selectedIndex == targetIndex, let currentSim = self.selectedSimulation else {
                    return
                }
                self.applyGroundSelection(guess, to: currentSim)
            }
        }
    }

    @objc private func groundNameChanged() {
        guard let sim = selectedSimulation else { return }
        let names = sim.groundNetKind == .net ? groundNetNames : groundNetClassNames
        let index = groundNamePopUp.indexOfSelectedItem
        guard index >= 0, index < names.count else { return }
        sim.groundNetName = names[index]
        document?.updateChangeCount(.changeDone)
        if let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
    }

    @objc private func numberFieldChanged(_ sender: NSTextField) {
        guard let document else { return }
        var affectsGeometry = false
        switch sender {
        case hullPaddingField:
            selectedSimulation?.hullPadding = sender.doubleValue
            affectsGeometry = true
        case viaEdgeDistanceField:
            selectedSimulation?.viaEdgeDistance = sender.doubleValue
            affectsGeometry = true
        case viaSpacingField:
            selectedSimulation?.viaSpacing = sender.doubleValue
            affectsGeometry = true
        case platingThicknessField: document.config.viaPlatingThickness = sender.doubleValue
        case fillingEpsilonField: document.config.viaFillingEpsilon = sender.doubleValue
        case frequencyStartField: document.config.frequencyStart = sender.doubleValue
        case frequencyStopField: document.config.frequencyStop = sender.doubleValue
        default: break
        }
        document.updateChangeCount(.changeDone)
        if affectsGeometry, let selectedIndex {
            onGeometryParametersChanged?(selectedIndex)
        }
    }
}
