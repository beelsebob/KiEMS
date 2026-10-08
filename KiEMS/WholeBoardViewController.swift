import Cocoa
import os

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
    /// Value field text. An unreadable value is called out in componentModelErrorBox.
    private let componentValueLabel = NSTextField(labelWithString: "")
    /// A selected component's own inclusion: the component equivalents of includedCheckbox and
    /// simulatedCheckbox/hullPaddingField (see kiems::IncludedComponentConfig). Disabled, with
    /// componentModelErrorBox saying why, unless the component has an R/L/C-only SPICE model.
    private let componentIncludedCheckbox = NSButton(checkboxWithTitle: "Included in Simulation", target: nil, action: nil)
    private let componentHullCheckbox = NSButton(checkboxWithTitle: "Contributes to Hull", target: nil, action: nil)
    private let componentHullPaddingField = NSTextField(string: "")
    private let componentHullPaddingFormatter = MicrometerValueFormatter()
    private let componentControls = NSStackView()
    private let componentModelErrorBox = NSBox()
    /// One row per warning -- see showComponentWarnings(_:note:).
    private let componentWarningRows = NSStackView()
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
    private let hullPaddingField = NSTextField(string: "")
    private let hullPaddingFormatter = MicrometerValueFormatter()
    private let impedanceProbedCheckbox = NSButton(checkboxWithTitle: "Impedance Probed", target: nil, action: nil)
    private let netClassIncludedCheckbox = NSButton(checkboxWithTitle: "Included in simulation", target: nil, action: nil)
    private let netClassSimulatedCheckbox = NSButton(checkboxWithTitle: "Contribute to Hull", target: nil, action: nil)
    private let netClassHullPaddingField = NSTextField(string: "")
    private let netClassHullPaddingFormatter = MicrometerValueFormatter()
    private let netClassImpedanceProbedCheckbox = NSButton(checkboxWithTitle: "Impedance Probed", target: nil, action: nil)
    private let excitedCheckbox = NSButton(checkboxWithTitle: "Excited", target: nil, action: nil)
    /// Primary (item 0) = a main excitation (isMain); Adversarial (item 1) = a non-main tone burst.
    private let excitationTypePopUp = NSPopUpButton()
    private let phaseField = NSTextField(string: "")
    private let relativeAmplitudeField = NSTextField(string: "")
    private let frequencyField = NSTextField(string: "")
    /// Adversarial only: Continuous (item 0) or Limited (item 1) -- see
    /// EMSExcitationBridge.hasContinuousDuration. durationField below it is shown only for Limited.
    private let durationModePopUp = NSPopUpButton()
    private let durationField = NSTextField(string: "")
    private let durationFormatter = UnitSuffixValueFormatter(
        displaySuffix: "s", acceptedSuffixes: ["seconds", "second", "secs", "sec", "s"], autoSelectsSIPrefix: true)
    private let phaseFormatter = PhaseValueFormatter()
    private let frequencyFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    private let pinImpedanceField = NSTextField(string: "")
    private let pinImpedanceFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Ω", acceptedSuffixes: ["ohms", "ohm", "Ω"])
    private let excitationControls = NSStackView()
    private var frequencyRow: NSStackView!
    private var durationModeRow: NSStackView!
    private var durationRow: NSStackView!
    private var pinImpedanceRow: NSStackView!
    private let probedCheckbox = NSButton(checkboxWithTitle: "Probed", target: nil, action: nil)
    private let absorbingCheckbox = NSButton(checkboxWithTitle: "Absorbing", target: nil, action: nil)
    private let netControls = NSStackView()
    private let netClassControls = NSStackView()
    private let pinControls = NSStackView()
    private var selection: GeometrySelection?
    private var selectedSimulationIndex: Int?
    private var selectedNetClassName: String?
    /// The selection's nets belong to different classes; selectedNetClassName is nil then.
    private var selectedNetClassIsMultiple = false
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

    /// Why each footprint without a usable SPICE model lacks one, by reference -- see
    /// KicadBoardBridge.componentSimModels(). Loaded alongside allFootprints; simModelsLoaded says
    /// whether it has been yet.
    private var unsupportedSimModelReasons: [String: String] = [:]
    private var simModelsLoaded = false
    /// Set when the schematic couldn't be read at all, which leaves every footprint without a
    /// model; updateSimModelReasons() then explains each one with this.
    private var simModelLoadError: String?

    /// Configuration edits invalidate the same downstream geometry/results state as the retired
    /// source-list editor. DocumentWindowController owns those caches and supplies this callback.
    var onConfigurationChanged: (() -> Void)?

    /// The initial window must not expose selectable simulations or an empty board while the real
    /// KiCad parse/mesh build is still running. DocumentWindowController uses this to replace its
    /// main content with a spinner and reveal the current selection only after loading completes.
    var onLoadingStateChanged: ((Bool) -> Void)?

    /// The kicadPcbPath refresh() last successfully loaded, so repeated calls
    /// from every simulation selection are a cheap no-op until invalidate() is called (the linked
    /// board actually changed on disk -- see DocumentWindowController.handleLinkedKicadFilesChanged)
    /// or a different board gets linked.
    private var loadedForPath: String?
    private var layerGeometryLoader: BoardLayerGeometryLoader?
    private var stitchingViaPlanRevision = 0
    /// Inputs of the plan currently shown or being computed; nil forces the next refresh to plan.
    private var stitchingViaPlanInputsKey: String?
    /// Plans run one at a time, and a queued plan that a newer edit has already superseded is
    /// skipped before it starts -- otherwise every intermediate edit (e.g. each step of a padding
    /// change) ran its own full plan concurrently, all competing with the one that will be shown.
    private let stitchingViaPlanQueue = DispatchQueue(label: "KiEMS.stitchingViaPlan", qos: .userInitiated)
    private let latestStitchingViaPlanRevision = OSAllocatedUnfairLock(initialState: 0)
    private var plannedStitchingViaPositions: [CGPoint] = []
    private var rejectedStitchingViaPositions: [CGPoint] = []
    private var plannedStitchingViaDiameter: CGFloat = 0
    private var hullCutTracePoints: [KicadHullCutTracePoint] = []

    /// Fixed -- this column stays narrow in every state, net/pin info and simulation settings alike
    /// (propertiesViewController's own layout is a single field-per-row column now, specifically so
    /// it fits here -- see SimulationPropertiesViewController.labeled()'s own doc comment).
    private static let infoPanelWidth: CGFloat = 264

    init(document: Document, propertiesViewController: SimulationPropertiesViewController) {
        self.document = document
        self.propertiesViewController = propertiesViewController
        super.init(nibName: nil, bundle: nil)
        propertiesViewController.onDifferentialPairEnabled = { [weak self] simulation in
            self?.reconcileDifferentialPairs(in: simulation)
        }
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
        let componentHullRow = NSStackView(views: [componentHullCheckbox, componentHullPaddingField])
        componentHullRow.orientation = .horizontal
        componentHullRow.alignment = .centerY
        componentHullRow.spacing = 6
        configureControlStack(componentControls, views: [componentIncludedCheckbox, componentHullRow])
        componentControls.isHidden = true
        for checkbox in [componentIncludedCheckbox, componentHullCheckbox] {
            checkbox.controlSize = .small
            checkbox.font = Self.formFont
        }
        componentIncludedCheckbox.target = self
        componentIncludedCheckbox.action = #selector(componentIncludedToggled)
        componentHullCheckbox.target = self
        componentHullCheckbox.action = #selector(componentHullToggled)
        componentHullPaddingField.formatter = componentHullPaddingFormatter
        componentHullPaddingField.target = self
        componentHullPaddingField.action = #selector(hullPaddingChanged(_:))
        componentHullPaddingField.controlSize = .small
        componentHullPaddingField.font = Self.formFont
        componentHullPaddingField.alignment = .right
        componentHullPaddingField.widthAnchor.constraint(equalToConstant: 74).isActive = true

        // Rows and colours depend on what the box is saying -- see showComponentWarnings(_:note:).
        componentWarningRows.orientation = .vertical
        componentWarningRows.alignment = .leading
        componentWarningRows.spacing = 6
        componentModelErrorBox.boxType = .custom
        componentModelErrorBox.cornerRadius = 5
        componentModelErrorBox.titlePosition = .noTitle
        componentModelErrorBox.contentViewMargins = NSSize(width: 8, height: 6)
        componentModelErrorBox.contentView = componentWarningRows
        componentModelErrorBox.isHidden = true
        configureHeadingStack(netHeading, views: [netHeadingPrefix, selectedNetView])
        configureHeadingStack(netClassHeading, views: [netClassHeadingPrefix, selectedNetClassView])
        pinSeparator.boxType = .separator
        netSeparator.boxType = .separator

        let hullContributionRow = NSStackView(views: [simulatedCheckbox, hullPaddingField])
        hullContributionRow.orientation = .horizontal
        hullContributionRow.alignment = .centerY
        hullContributionRow.spacing = 6
        let netClassHullContributionRow = NSStackView(views: [netClassSimulatedCheckbox, netClassHullPaddingField])
        netClassHullContributionRow.orientation = .horizontal
        netClassHullContributionRow.alignment = .centerY
        netClassHullContributionRow.spacing = 6
        configureControlStack(netControls, views: [includedCheckbox, hullContributionRow, impedanceProbedCheckbox])
        configureControlStack(netClassControls,
                              views: [netClassIncludedCheckbox, netClassHullContributionRow,
                                      netClassImpedanceProbedCheckbox])
        for checkbox in [includedCheckbox, simulatedCheckbox, impedanceProbedCheckbox,
                         netClassIncludedCheckbox, netClassSimulatedCheckbox,
                         netClassImpedanceProbedCheckbox, excitedCheckbox,
                         probedCheckbox, absorbingCheckbox] {
            checkbox.controlSize = .small
            checkbox.font = Self.formFont
        }
        phaseField.formatter = phaseFormatter
        frequencyField.formatter = frequencyFormatter
        durationField.formatter = durationFormatter
        relativeAmplitudeField.formatter = Self.numberFormatter
        for field in [phaseField, relativeAmplitudeField, frequencyField, durationField] {
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
        excitationTypePopUp.addItems(withTitles: ["Primary", "Adversarial"])
        excitationTypePopUp.controlSize = .small
        excitationTypePopUp.font = Self.formFont
        excitationTypePopUp.target = self
        excitationTypePopUp.action = #selector(excitationTypeChanged)
        frequencyRow = excitationValueRow(title: "Frequency:", field: frequencyField)
        durationModePopUp.addItems(withTitles: ["Continuous", "Limited"])
        durationModePopUp.controlSize = .small
        durationModePopUp.font = Self.formFont
        durationModePopUp.target = self
        durationModePopUp.action = #selector(durationModeChanged)
        durationModeRow = excitationValueRow(title: "Duration:", field: durationModePopUp)
        // No label of its own: it sits directly beneath, and belongs to, the Duration popup.
        durationRow = excitationValueRow(title: "", field: durationField)
        let phaseRow = excitationValueRow(title: "Phase:", field: phaseField)
        let relativeAmplitudeRow = excitationValueRow(title: "Relative Amplitude:", field: relativeAmplitudeField)
        configureControlStack(excitationControls, views: [
            excitationValueRow(title: "Type:", field: excitationTypePopUp),
            phaseRow,
            relativeAmplitudeRow,
            frequencyRow,
            durationModeRow,
            durationRow,
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
        hullPaddingField.formatter = hullPaddingFormatter
        hullPaddingField.target = self
        hullPaddingField.action = #selector(hullPaddingChanged(_:))
        hullPaddingField.controlSize = .small
        hullPaddingField.font = Self.formFont
        hullPaddingField.alignment = .right
        hullPaddingField.widthAnchor.constraint(equalToConstant: 74).isActive = true
        impedanceProbedCheckbox.target = self
        impedanceProbedCheckbox.action = #selector(impedanceProbedToggled)
        netClassIncludedCheckbox.target = self
        netClassIncludedCheckbox.action = #selector(netClassIncludedToggled)
        netClassSimulatedCheckbox.target = self
        netClassSimulatedCheckbox.action = #selector(netClassSimulatedToggled)
        netClassHullPaddingField.formatter = netClassHullPaddingFormatter
        netClassHullPaddingField.target = self
        netClassHullPaddingField.action = #selector(hullPaddingChanged(_:))
        netClassHullPaddingField.controlSize = .small
        netClassHullPaddingField.font = Self.formFont
        netClassHullPaddingField.alignment = .right
        netClassHullPaddingField.widthAnchor.constraint(equalToConstant: 74).isActive = true
        netClassImpedanceProbedCheckbox.target = self
        netClassImpedanceProbedCheckbox.action = #selector(netClassImpedanceProbedToggled)
        excitedCheckbox.target = self
        excitedCheckbox.action = #selector(excitedToggled)
        probedCheckbox.target = self
        probedCheckbox.action = #selector(probedToggled)
        absorbingCheckbox.target = self
        absorbingCheckbox.action = #selector(absorbingToggled)

        let infoStack = NSStackView(views: [infoTitle, pinHeading, componentValueLabel, componentControls,
                                            componentModelErrorBox, pinControls, pinSeparator,
                                            netHeading, netControls, netSeparator,
                                            netClassHeading, netClassControls])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 6
        infoStack.setCustomSpacing(16, after: infoTitle)
        infoStack.setCustomSpacing(4, after: pinHeading)
        infoStack.setCustomSpacing(10, after: componentValueLabel)
        infoStack.setCustomSpacing(14, after: componentControls)
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

        boardView.contextMenuForSelection = { [weak self] selection in
            self?.contextMenu(for: selection)
        }
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
            componentModelErrorBox.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            netSeparator.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            netHeading.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            netClassHeading.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            // Excitation value rows fill the sidebar from their 16pt subordinate-option indent to
            // the ordinary right content edge. Their text fields have low horizontal hugging, so
            // the recovered width goes to the editable value rather than becoming empty space.
            phaseRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor, constant: -16),
            relativeAmplitudeRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor, constant: -16),
            frequencyRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor, constant: -16),
            durationRow.widthAnchor.constraint(equalTo: infoStack.widthAnchor, constant: -16),
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

    private func excitationValueRow(title: String, field: NSControl) -> NSStackView {
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

    private func populateExcitationControls(from excitation: EMSExcitationBridge) {
        excitationTypePopUp.isEnabled = true
        excitationTypePopUp.selectItem(at: excitation.isMain ? 0 : 1)
        phaseField.doubleValue = excitation.phaseDegrees
        relativeAmplitudeField.objectValue = excitation.amplitude ?? NSNumber(value: 1)
        frequencyField.objectValue = excitation.frequency ?? NSNumber(value: document?.config.frequencyStart ?? 0)
        durationModePopUp.selectItem(at: excitation.hasContinuousDuration ? 0 : 1)
        durationField.doubleValue = excitation.duration
        frequencyRow.isHidden = excitation.isMain
        durationModeRow.isHidden = excitation.isMain
        durationRow.isHidden = excitation.isMain || excitation.hasContinuousDuration
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
    /// The nets whose class the Net Class field describes: every net of a group selection, or the
    /// selection's own net.
    private var netClassSourceNets: [String] {
        if case let .connectedNets(members, _, _)? = selection?.kind, !members.isEmpty { return members }
        guard let netName = selection?.netName, !netName.isEmpty else { return [] }
        return [netName]
    }

    /// Whether the selection spans several nets, which the Net field shows as "<Multiple>". The
    /// single-net controls are disabled then, rather than acting on just one of them.
    private var selectionHasMultipleNets: Bool {
        if case let .connectedNets(members, _, _)? = selection?.kind { return members.count > 1 }
        return false
    }

    private func resolveNetClassForSelection() {
        let nets = netClassSourceNets
        guard !nets.isEmpty, let board = document?.board else {
            applyNetClasses(of: [])
            return
        }
        let missing = nets.filter { netClassByNet[$0] == nil }
        if missing.isEmpty {
            applyNetClasses(of: nets)
            return
        }

        selectedNetClassName = nil
        selectedNetClassIsMultiple = false
        isLoadingSelectedNetClass = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = missing.map { (net: $0, netClass: (try? board.netClass(forNet: $0)) ?? "") }
            DispatchQueue.main.async {
                guard let self, self.loadedForPath == board.kicadPcbPath else { return }
                for (net, netClass) in resolved { self.netClassByNet[net] = netClass }
                guard self.netClassSourceNets == nets else { return }
                self.applyNetClasses(of: nets)
                self.updateConfigurationControls()
            }
        }
    }

    /// Sets the Net Class field's state from already-resolved `nets`: their one shared class (or
    /// none), or "<Multiple>" when they differ.
    private func applyNetClasses(of nets: [String]) {
        let classes = Set(nets.compactMap { netClassByNet[$0] })
        isLoadingSelectedNetClass = false
        selectedNetClassIsMultiple = classes.count > 1
        selectedNetClassName = classes.count == 1 ? classes.first.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    private func excitationIndex(reference: String, pin: String, in simulation: EMSSimulationBridge) -> Int? {
        simulation.excitations.firstIndex { $0.footprintReference == reference && $0.pin == pin }
    }

    private func excitation(reference: String, pin: String, in simulation: EMSSimulationBridge) -> EMSExcitationBridge? {
        excitationIndex(reference: reference, pin: pin, in: simulation).map { simulation.excitations[$0] }
    }

    private func hullCutPortIndex(identifier: String, in simulation: EMSSimulationBridge) -> Int? {
        simulation.hullCutPorts.firstIndex { $0.identifier == identifier }
    }

    private func hullCutPort(identifier: String, in simulation: EMSSimulationBridge) -> EMSHullCutPortBridge? {
        hullCutPortIndex(identifier: identifier, in: simulation).map { simulation.hullCutPorts[$0] }
    }

    private func hullCutExcitationIndex(identifier: String, in simulation: EMSSimulationBridge) -> Int? {
        simulation.excitations.firstIndex { $0.hullCutPortID == identifier }
    }

    private func hullCutExcitation(identifier: String, in simulation: EMSSimulationBridge) -> EMSExcitationBridge? {
        hullCutExcitationIndex(identifier: identifier, in: simulation).map { simulation.excitations[$0] }
    }

    private func hullCutPoint(identifier: String) -> KicadHullCutTracePoint? {
        hullCutTracePoints.first { $0.identifier == identifier }
    }

    private func ensureHullCutPort(identifier: String, in simulation: EMSSimulationBridge) -> EMSHullCutPortBridge? {
        if let existing = hullCutPort(identifier: identifier, in: simulation) { return existing }
        guard let point = hullCutPoint(identifier: identifier) else { return nil }
        // Candidate coordinates are simulation units (0.1um). Persist the port in configuration
        // micrometres, inset by half its square footprint so it lies on retained trace copper.
        let lengthSim = max(point.traceWidth, 1)
        let radians = point.inwardDirection * .pi / 180
        let centerX = point.position.x + cos(radians) * lengthSim / 2
        let centerY = point.position.y + sin(radians) * lengthSim / 2
        return simulation.addHullCutPort(withIdentifier: identifier, net: point.netName,
                                         layer: point.layerName, x: centerX / 10, y: centerY / 10,
                                         direction: point.inwardDirection,
                                         width: point.traceWidth / 10, length: lengthSim / 10)
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

    /// Brings everything already configured on `simulation` to the state it would have reached had
    /// isDifferentialPair been on while it was being added -- called when the Differential Pair
    /// checkbox is ticked (SimulationPropertiesViewController.onDifferentialPairEnabled), so
    /// "add nets, then tick" and "tick, then add nets" produce the same configuration. For every
    /// Net-kind entry whose heuristic partner net exists on the board: includes the partner at the
    /// same level, marks the pair, and mirrors each explicit pin choice and excitation onto the
    /// partner pin of the same footprint, exactly as includedToggled()/probedToggled()/
    /// absorbingToggled()/excitedToggled() do one pin at a time. Existing partner-side state is
    /// never overwritten, and entries already paired with some other net are left alone.
    func reconcileDifferentialPairs(in simulation: EMSSimulationBridge) {
        let netNames = simulation.involvedNets.compactMap { $0.kind == .net ? $0.net : nil }
        for netName in netNames {
            guard let entry = involvedNet(named: netName, in: simulation),
                  let partnerName = differentialPairPartnerNetName(for: netName),
                  entry.differentialPairPartner == nil || entry.differentialPairPartner == partnerName
            else { continue }
            if let partner = involvedNet(named: partnerName, in: simulation) {
                guard partner.differentialPairPartner == nil || partner.differentialPairPartner == netName
                else { continue }
                if entry.inclusionLevel == .simulationNet {
                    partner.inclusionLevel = .simulationNet
                }
            } else if entry.inclusionLevel == .simulationNet {
                includeNet(named: partnerName, in: simulation)
            } else {
                includeNetGeometryOnly(named: partnerName, in: simulation)
            }
            markDifferentialPair(netName, partnerName, in: simulation)

            for pin in entry.probedPins {
                guard let partnerPin = differentialPairPartnerPin(footprintReference: pin.footprintReference,
                                                                  netName: netName),
                      partnerPin.netName == partnerName, partnerPin.number != pin.pin,
                      let partnerEntry = involvedNet(named: partnerName, in: simulation),
                      !partnerEntry.probedPins.contains(where: {
                          $0.footprintReference == pin.footprintReference && $0.pin == partnerPin.number
                      })
                else { continue }
                if pin.probe {
                    applyProbed(true, absorbing: pin.absorbSignal, footprintReference: pin.footprintReference,
                                netName: partnerName, padNumber: partnerPin.number, in: simulation)
                } else {
                    applyAbsorbing(pin.absorbSignal, probed: false, footprintReference: pin.footprintReference,
                                   netName: partnerName, padNumber: partnerPin.number, in: simulation)
                }
            }
        }

        for source in simulation.excitations where source.hullCutPortID == nil {
            let reference = source.footprintReference
            guard let netName = allFootprints.first(where: { $0.reference == reference })?.pins
                      .first(where: { $0.number == source.pin })?.netName,
                  let partnerPin = differentialPairPartnerPin(footprintReference: reference, netName: netName),
                  partnerPin.number != source.pin,
                  involvedNet(named: netName, in: simulation)?.differentialPairPartner == partnerPin.netName,
                  excitation(reference: reference, pin: partnerPin.number, in: simulation) == nil
            else { continue }
            applyExcited(true, footprintReference: reference, netName: partnerPin.netName,
                         padNumber: partnerPin.number, in: simulation)
            if let mirrored = excitation(reference: reference, pin: partnerPin.number, in: simulation) {
                configureDifferentialComplement(mirrored, from: source)
            }
        }
        configurationChanged()
    }

    /// Makes a just-added excitation an ideal odd-mode drive relative to `source` -- mirrors
    /// SourceListViewController's identical helper. Independent FDTD sweeps still use unit
    /// single-port sources; these relative settings are consumed when their responses are
    /// superposed by ExcitationPostprocessor.
    private func configureDifferentialComplement(_ partner: EMSExcitationBridge, from source: EMSExcitationBridge) {
        partner.isMain = source.isMain
        partner.hasContinuousDuration = source.hasContinuousDuration
        partner.startTime = source.startTime
        partner.duration = source.duration
        partner.frequency = source.frequency
        partner.phaseDegrees = source.phaseDegrees
        partner.amplitude = NSNumber(value: -(source.amplitude?.doubleValue ?? 1.0))
    }

    /// Matches the parts the simulator can model as lumped components: an exact, single-letter
    /// R/L/C designator prefix is passive; networks and specialised multi-letter variants are not.
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

    private func includedComponent(_ reference: String,
                                   in simulation: EMSSimulationBridge) -> EMSIncludedComponentBridge? {
        simulation.includedComponents.first { $0.reference == reference }
    }

    /// The component equivalent of the net controls: only a component whose SPICE model KiEMS can
    /// simulate (see kiems::assessComponentSimModel()) can be included; for anything else both
    /// checkboxes are greyed out and componentModelErrorBox says why. One that is already included
    /// can still be removed.
    private func updateComponentControls(reference: String) {
        componentControls.isHidden = false
        componentIncludedCheckbox.allowsMixedState = false
        componentHullCheckbox.allowsMixedState = false
        componentHullPaddingField.placeholderString = nil
        let simulation = selectedSimulation
        let entry = simulation.flatMap { includedComponent(reference, in: $0) }
        componentIncludedCheckbox.state = entry != nil ? .on : .off
        componentHullCheckbox.state = entry?.contributesToHull == true ? .on : .off
        if let entry {
            componentHullPaddingField.doubleValue = entry.hullPadding
        } else {
            componentHullPaddingField.stringValue = ""
        }

        let modelProblem = simModelsLoaded ? unsupportedSimModelReasons[reference] : nil
        let usable = simModelsLoaded && modelProblem == nil
        componentIncludedCheckbox.isEnabled = simulation != nil && (usable || entry != nil)
        componentHullCheckbox.isEnabled = simulation != nil && usable && entry != nil
        componentHullPaddingField.isEnabled = simulation != nil && usable && entry?.contributesToHull == true

        // An unreadable value doesn't stop the part being included, but the simulator will skip it.
        let warnings = [modelProblem, valueWarning(for: reference)].compactMap { $0 }
        showComponentWarnings(warnings,
                              note: simModelsLoaded ? nil : "Checking the schematic for this component's SPICE model…")
    }

    /// One net or component of a group selection, as the group controls see it.
    private struct GroupPart {
        let isIncluded: Bool
        let contributesToHull: Bool
        let padding: Double
        let setPadding: (Double) -> Void
    }

    /// A group's includable parts -- its nets, and its components with a usable SPICE model --
    /// plus the components left out for want of one.
    private func groupParts(nets: [String], components: [String], in simulation: EMSSimulationBridge)
        -> (all: [GroupPart], contributing: [GroupPart], unusable: [String]) {
        var all: [GroupPart] = []
        for net in nets {
            let entry = involvedNet(named: net, in: simulation)
            all.append(GroupPart(isIncluded: entry != nil, contributesToHull: entry?.inclusionLevel == .simulationNet,
                                 padding: entry?.hullPadding ?? 0, setPadding: { entry?.hullPadding = $0 }))
        }
        var unusable: [String] = []
        for reference in components {
            let entry = includedComponent(reference, in: simulation)
            guard entry != nil || (simModelsLoaded && unsupportedSimModelReasons[reference] == nil) else {
                unusable.append(reference)
                continue
            }
            all.append(GroupPart(isIncluded: entry != nil, contributesToHull: entry?.contributesToHull == true,
                                 padding: entry?.hullPadding ?? 0, setPadding: { entry?.hullPadding = $0 }))
        }
        return (all, all.filter { $0.isIncluded && $0.contributesToHull }, unusable)
    }

    /// The group equivalent of updateComponentControls(reference:): the same two checkboxes, mixed
    /// when the group's parts disagree, acting on every net and usable component together.
    private func updateGroupControls(nets: [String], components: [String]) {
        componentControls.isHidden = false
        componentIncludedCheckbox.allowsMixedState = true
        componentHullCheckbox.allowsMixedState = true
        guard let simulation = selectedSimulation else {
            componentIncludedCheckbox.state = .off
            componentHullCheckbox.state = .off
            componentHullPaddingField.stringValue = ""
            for control in [componentIncludedCheckbox, componentHullCheckbox, componentHullPaddingField] as [NSControl] {
                control.isEnabled = false
            }
            return
        }
        let parts = groupParts(nets: nets, components: components, in: simulation)
        let included = parts.all.filter(\.isIncluded)
        func state(_ count: Int, of total: Int) -> NSControl.StateValue {
            count == 0 ? .off : count == total ? .on : .mixed
        }
        componentIncludedCheckbox.state = state(included.count, of: parts.all.count)
        componentIncludedCheckbox.isEnabled = !parts.all.isEmpty
        componentHullCheckbox.state = state(parts.contributing.count, of: included.count)
        componentHullCheckbox.isEnabled = !included.isEmpty
        let paddings = Set(parts.contributing.map(\.padding))
        if paddings.count == 1, let padding = paddings.first {
            componentHullPaddingField.doubleValue = padding
        } else {
            componentHullPaddingField.stringValue = ""
        }
        componentHullPaddingField.placeholderString = paddings.count > 1 ? "Multiple" : nil
        componentHullPaddingField.isEnabled = !parts.contributing.isEmpty

        func list(_ references: [String]) -> String {
            let more = references.count > 4 ? " and \(references.count - 4) more" : ""
            return references.prefix(4).joined(separator: ", ") + more
        }
        var warnings: [String] = []
        if simModelsLoaded && !parts.unusable.isEmpty {
            warnings.append("Left out, with no SPICE model of only R, L and C: \(list(parts.unusable))")
        }
        let unreadable = components.filter { !parts.unusable.contains($0) && valueWarning(for: $0) != nil }
        if !unreadable.isEmpty {
            warnings.append("Could not read the value of \(list(unreadable))")
        }
        showComponentWarnings(warnings, note: !simModelsLoaded && !components.isEmpty
                                  ? "Checking the schematic for these components' SPICE models…" : nil)
    }

    /// The warning for an R/L/C part whose Value the simulator can't read, if it can't.
    private func valueWarning(for reference: String) -> String? {
        guard let unit = lumpedComponentUnit(forReference: reference),
              let footprint = allFootprints.first(where: { $0.reference == reference }),
              !EMSConfigBridge.componentValueIsSensible(footprint.value, unit: unit)
        else { return nil }
        return footprint.value.isEmpty ? "No value given" : "Could not read value \"\(footprint.value)\""
    }

    /// Fills componentModelErrorBox with one row per warning, each with a caution sign in its
    /// yellow, then `note` (the schematic still being read, which isn't a problem) in neutral grey
    /// without one. Hides the box when there's nothing to say.
    private func showComponentWarnings(_ warnings: [String], note: String?) {
        for row in componentWarningRows.arrangedSubviews { row.removeFromSuperview() }
        func row(_ text: String, color: NSColor, caution: Bool) -> NSView {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = Self.formFont
            label.textColor = color
            label.preferredMaxLayoutWidth = Self.infoPanelWidth - (caution ? 62 : 40)
            guard caution else { return label }
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: "Caution")!)
            icon.contentTintColor = color
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let stack = NSStackView(views: [icon, label])
            stack.orientation = .horizontal
            stack.alignment = .top
            stack.spacing = 6
            return stack
        }
        for warning in warnings {
            componentWarningRows.addArrangedSubview(row(warning, color: .systemYellow, caution: true))
        }
        if let note {
            componentWarningRows.addArrangedSubview(row(note, color: .secondaryLabelColor, caution: false))
        }
        let tint: NSColor = warnings.isEmpty ? .secondaryLabelColor : .systemYellow
        componentModelErrorBox.borderColor = tint
        componentModelErrorBox.fillColor = tint.withAlphaComponent(0.1)
        componentModelErrorBox.isHidden = warnings.isEmpty && note == nil
    }

    /// Includes every part unless all are already included, in which case removes them all.
    private func groupIncludedToggled(nets: [String], components: [String]) {
        guard let simulation = selectedSimulation else { return }
        let parts = groupParts(nets: nets, components: components, in: simulation)
        let include = !parts.all.allSatisfy(\.isIncluded)
        for net in nets { applyNetIncluded(include, netName: net, in: simulation) }
        for reference in components where !parts.unusable.contains(reference) {
            if include {
                simulation.includeComponent(withReference: reference)
            } else {
                simulation.removeIncludedComponent(withReference: reference)
            }
        }
        configurationChanged()
    }

    /// Makes every included part contribute to the hull unless all already do, in which case none.
    private func groupHullToggled(nets: [String], components: [String]) {
        guard let simulation = selectedSimulation else { return }
        let parts = groupParts(nets: nets, components: components, in: simulation)
        let included = parts.all.filter(\.isIncluded)
        let contribute = parts.contributing.count < included.count
        for net in nets {
            guard let entry = involvedNet(named: net, in: simulation) else { continue }
            entry.inclusionLevel = contribute ? .simulationNet : .geometryOnly
        }
        for reference in components {
            includedComponent(reference, in: simulation)?.contributesToHull = contribute
        }
        configurationChanged()
    }

    private func pinKey(reference: String, number: String) -> PinKey? {
        guard let selectedSimulationIndex else { return nil }
        return PinKey(simulationIndex: selectedSimulationIndex, reference: reference, number: number)
    }

    private func updateConfigurationControls() {
        let hasSimulation = selectedSimulation != nil
        includedCheckbox.isEnabled = false
        simulatedCheckbox.isEnabled = false
        hullPaddingField.isEnabled = false
        impedanceProbedCheckbox.isEnabled = false
        netClassIncludedCheckbox.isEnabled = false
        netClassSimulatedCheckbox.isEnabled = false
        netClassHullPaddingField.isEnabled = false
        netClassImpedanceProbedCheckbox.isEnabled = false
        excitedCheckbox.isEnabled = false
        excitationTypePopUp.isEnabled = false
        probedCheckbox.isEnabled = false
        absorbingCheckbox.isEnabled = false
        pinImpedanceField.isEnabled = false

        includedCheckbox.state = .off
        simulatedCheckbox.state = .off
        hullPaddingField.stringValue = ""
        impedanceProbedCheckbox.state = .off
        netClassIncludedCheckbox.state = .off
        netClassSimulatedCheckbox.state = .off
        netClassHullPaddingField.stringValue = ""
        netClassImpedanceProbedCheckbox.state = .off
        excitedCheckbox.state = .off
        excitationTypePopUp.selectItem(at: 0)
        excitationControls.isHidden = true
        probedCheckbox.state = .off
        absorbingCheckbox.state = .off
        pinImpedanceField.objectValue = NSNumber(value: 45)
        componentControls.isHidden = true
        componentModelErrorBox.isHidden = true

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
        // below apply to it; its own case in the switch below shows its reference, value and
        // inclusion.
        var isComponentSelection = false
        if case .component = selection.kind {
            isComponentSelection = true
        }
        netHeading.isHidden = isComponentSelection
        netControls.isHidden = isComponentSelection
        netSeparator.isHidden = isComponentSelection
        netClassHeading.isHidden = isComponentSelection
        netClassControls.isHidden = isComponentSelection

        let netName = isComponentSelection || selectionHasMultipleNets ? "" : (selection.netName ?? "")
        guard !isComponentSelection else {
            switch selection.kind {
            case let .component(reference):
                pinHeading.isHidden = false
                pinHeading.stringValue = "Component: \(reference)"
                pinSeparator.isHidden = true
                pinControls.isHidden = true
                if lumpedComponentUnit(forReference: reference) != nil,
                   let footprint = allFootprints.first(where: { $0.reference == reference }) {
                    let value = footprint.value.isEmpty ? "(none)" : footprint.value
                    componentValueLabel.stringValue = "Value: \(value)"
                    componentValueLabel.textColor = .labelColor
                    componentValueLabel.isHidden = false
                } else {
                    componentValueLabel.isHidden = true
                }
                updateComponentControls(reference: reference)
            case .net, .pin, .hullCutPort, .connectedNets:
                break // unreachable -- isComponentSelection is only true for .component
            }
            return
        }
        if selectionHasMultipleNets {
            selectedNetView.configure(name: "<Multiple>", font: detailFont, color: .labelColor)
        } else {
            selectedNetView.configure(name: netName.isEmpty ? "No net" : netName, font: detailFont,
                                      color: netName.isEmpty ? .secondaryLabelColor : .labelColor)
        }
        includedCheckbox.isEnabled = hasSimulation && !netName.isEmpty
        if let simulation = selectedSimulation, !netName.isEmpty,
           let entry = involvedNet(named: netName, in: simulation) {
            let simulated = entry.inclusionLevel == .simulationNet
            includedCheckbox.state = .on
            simulatedCheckbox.state = simulated ? .on : .off
            simulatedCheckbox.isEnabled = true
            hullPaddingField.doubleValue = entry.hullPadding
            hullPaddingField.isEnabled = simulated
            impedanceProbedCheckbox.state = entry.probeImpedance ? .on : .off
            impedanceProbedCheckbox.isEnabled = simulated
        }

        let netClassDisplayName: String
        if isLoadingSelectedNetClass {
            netClassDisplayName = "Loading…"
        } else {
            netClassDisplayName = selectedNetClassIsMultiple ? "<Multiple>" : selectedNetClassName ?? "No net class"
        }
        selectedNetClassView.configure(name: netClassDisplayName, font: detailFont,
                                       color: selectedNetClassName == nil && !selectedNetClassIsMultiple
                                           ? .secondaryLabelColor : .labelColor)
        if let simulation = selectedSimulation, let netClassName = selectedNetClassName,
           !netClassName.isEmpty {
            netClassIncludedCheckbox.isEnabled = true
            if let entry = involvedNetClass(named: netClassName, in: simulation) {
                let simulated = entry.inclusionLevel == .simulationNet
                netClassIncludedCheckbox.state = .on
                netClassSimulatedCheckbox.state = simulated ? .on : .off
                netClassSimulatedCheckbox.isEnabled = true
                netClassHullPaddingField.doubleValue = entry.hullPadding
                netClassHullPaddingField.isEnabled = simulated
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

        case let .connectedNets(members, components, pins):
            pinHeading.isHidden = false
            func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
            pinHeading.stringValue = [count(members.count, "net"), count(components.count, "component"),
                                      count(pins.count, "pin")].compactMap { $0 }.joined(separator: ", ")
            pinSeparator.isHidden = true
            pinControls.isHidden = true
            componentValueLabel.isHidden = true
            // A group is edited as a whole, not through any one net's or class's controls.
            for view in [netHeading, netControls, netSeparator, netClassHeading, netClassControls] {
                view.isHidden = true
            }
            updateGroupControls(nets: members, components: components)

        case .component:
            break // handled above, before isComponentSelection's early return

        case let .hullCutPort(identifier):
            pinHeading.isHidden = false
            pinHeading.stringValue = "Hull Cut Port"
            pinSeparator.isHidden = false
            pinControls.isHidden = false
            componentValueLabel.isHidden = true
            excitedCheckbox.isEnabled = hasSimulation
            probedCheckbox.isEnabled = hasSimulation
            absorbingCheckbox.isEnabled = hasSimulation
            pinImpedanceField.isEnabled = hasSimulation
            guard let simulation = selectedSimulation else { return }
            if let port = hullCutPort(identifier: identifier, in: simulation) {
                probedCheckbox.state = port.probe ? .on : .off
                absorbingCheckbox.state = port.absorbSignal ? .on : .off
                pinImpedanceField.doubleValue = port.impedance
            }
            if let excitation = hullCutExcitation(identifier: identifier, in: simulation) {
                excitedCheckbox.state = .on
                absorbingCheckbox.state = .on
                excitationControls.isHidden = false
                populateExcitationControls(from: excitation)
            }

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
                populateExcitationControls(from: excitation)
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
        highlight.plannedStitchingViaPositions = plannedStitchingViaPositions
        highlight.rejectedStitchingViaPositions = rejectedStitchingViaPositions
        highlight.plannedStitchingViaDiameter = plannedStitchingViaDiameter
        for point in hullCutTracePoints {
            let port = hullCutPort(identifier: point.identifier, in: simulation)
            highlight.hullCutPortSpots.append(BoardActivityHighlight.HullCutPortSpot(
                identifier: point.identifier, netName: point.netName, layerName: point.layerName,
                position: point.position,
                excited: hullCutExcitation(identifier: point.identifier, in: simulation) != nil,
                probed: port?.probe ?? false, absorbing: port?.absorbSignal ?? false))
        }
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
                for net in memberNets {
                    highlight.hullPaddingByNet[net] = max(highlight.hullPaddingByNet[net] ?? 0,
                                                          entry.hullPadding)
                }
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
        // Included components are the simulation's lumped parts (port_resolution.cpp's
        // _resolveLumpedComponents()): each is involved and may grow the hull; a two-pin R/L/C
        // bridges its two nets in the activity graph, and is flagged if its Value is unusable,
        // because the simulator will skip it.
        for component in simulation.includedComponents {
            let reference = component.reference
            highlight.involvedComponentReferences.insert(reference)
            if component.contributesToHull {
                highlight.hullPaddingByComponent[reference] = component.hullPadding
            }
            guard let footprint = footprintByReference[reference], footprint.pins.count == 2,
                  isPassive(reference: reference)
            else { continue }
            let first = footprint.pins[0]
            let second = footprint.pins[1]
            guard !first.netName.isEmpty, !second.netName.isEmpty, first.netName != second.netName else { continue }
            highlight.passiveBridges.append(BoardActivityHighlight.PassiveBridge(
                reference: reference, firstPad: first.number, firstNet: first.netName,
                secondPad: second.number, secondNet: second.netName))
            if let unit = lumpedComponentUnit(forReference: reference),
               !EMSConfigBridge.componentValueIsSensible(footprint.value, unit: unit) {
                highlight.invalidComponentReferences.insert(reference)
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
        let request: KicadStitchingViaPlanRequest?
        if let document, let selectedSimulationIndex,
           let boardPath = document.config.kicadPcbPath,
           loadedForPath == boardPath, boardView.preview != nil {
            request = KicadBoardBridge.stitchingViaPlanRequest(
                forConfig: document.config, simulationIndex: selectedSimulationIndex)
        } else {
            request = nil
        }
        // Most configuration edits (ports, probes, absorbing, excitations, ...) can't move the cut
        // or its vias. Keep the current plan -- and its clickable hull-cut points -- unless one of
        // the plan's own inputs actually changed.
        let inputsKey = request.map { "\(loadedForPath ?? "")\n\(selectedSimulationIndex ?? -1)\n\($0.inputsKey)" }
        if let inputsKey, inputsKey == stitchingViaPlanInputsKey {
            boardView.activity = computeActivityHighlight()
            return
        }
        stitchingViaPlanInputsKey = inputsKey

        stitchingViaPlanRevision += 1
        let revision = stitchingViaPlanRevision
        plannedStitchingViaPositions = []
        rejectedStitchingViaPositions = []
        plannedStitchingViaDiameter = 0
        hullCutTracePoints = []
        guard let document, let selectedSimulationIndex,
              let board = document.board, let request
        else {
            boardView.activity = computeActivityHighlight()
            return
        }
        boardView.activity = computeActivityHighlight()
        latestStitchingViaPlanRevision.withLock { $0 = revision }
        let latestRevision = latestStitchingViaPlanRevision
        stitchingViaPlanQueue.async { [weak self] in
            guard latestRevision.withLock({ $0 }) == revision else { return }
            let plan: KicadStitchingViaPlan?
            let planningError: Error?
            let signposter = OSSignposter(subsystem: "com.kiems", category: "BoardLoad")
            let signpost = signposter.beginInterval("Stitching via plan")
            defer { signposter.endInterval("Stitching via plan", signpost) }
            do {
                plan = try request.compute(withBoard: board)
                planningError = nil
            } catch {
                plan = nil
                planningError = error
            }
            DispatchQueue.main.async {
                guard let self, self.stitchingViaPlanRevision == revision,
                      self.loadedForPath == board.kicadPcbPath,
                      self.selectedSimulationIndex == selectedSimulationIndex else { return }
                if let planningError {
                    NSLog("Hull-cut/via planning failed: %@", planningError.localizedDescription)
                }
#if DEBUG
                NSLog("Hull-cut planning found %ld candidate(s) for simulation index %ld",
                      plan?.hullCutTracePoints.count ?? 0, selectedSimulationIndex)
#endif
                self.plannedStitchingViaPositions = plan?.placedPositions.map(\.pointValue) ?? []
                self.rejectedStitchingViaPositions = plan?.rejectedPositions.map(\.pointValue) ?? []
                self.plannedStitchingViaDiameter = CGFloat(plan?.annularRingDiameter ?? 0)
                self.hullCutTracePoints = plan?.hullCutTracePoints ?? []
                self.boardView.activity = self.computeActivityHighlight()
            }
        }
    }

    /// Expands every selected net-class entry once per loaded board. The immediate highlight uses
    /// any cached classes; each newly completed query refreshes it, so neither board loading nor a
    /// checkbox edit blocks the UI on board parsing.
    private func resolveActivityNetClassesIfNeeded() {
        guard let simulation = selectedSimulation,
              let board = document?.board else { return }
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
                let members = (try? board.nets(inNetClass: netClass)) ?? []
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.resolvingActivityNetClasses.remove(netClass)
                    guard self.loadedForPath == board.kicadPcbPath else { return }
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

    @objc private func hullPaddingChanged(_ sender: NSTextField) {
        guard let simulation = selectedSimulation else { return }
        let padding = max(sender.doubleValue, 0)
        if sender === hullPaddingField, let netName = selection?.netName,
           let entry = involvedNet(named: netName, in: simulation),
           entry.inclusionLevel == .simulationNet {
            entry.hullPadding = padding
        } else if sender === netClassHullPaddingField, let netClassName = selectedNetClassName,
                  let entry = involvedNetClass(named: netClassName, in: simulation),
                  entry.inclusionLevel == .simulationNet {
            entry.hullPadding = padding
        } else if sender === componentHullPaddingField, case let .component(reference)? = selection?.kind,
                  let entry = includedComponent(reference, in: simulation), entry.contributesToHull {
            entry.hullPadding = padding
        } else if sender === componentHullPaddingField,
                  case let .connectedNets(members, components, _)? = selection?.kind {
            let parts = groupParts(nets: members, components: components, in: simulation)
            guard !parts.contributing.isEmpty else { return }
            for part in parts.contributing { part.setPadding(padding) }
        } else {
            return
        }
        sender.doubleValue = padding
        configurationChanged()
    }

    @objc private func componentIncludedToggled() {
        if case let .connectedNets(members, components, _)? = selection?.kind {
            groupIncludedToggled(nets: members, components: components)
            return
        }
        guard case let .component(reference)? = selection?.kind, let simulation = selectedSimulation else { return }
        if componentIncludedCheckbox.state == .on {
            simulation.includeComponent(withReference: reference)
        } else {
            simulation.removeIncludedComponent(withReference: reference)
        }
        configurationChanged()
    }

    /// Like simulatedToggled(), this never removes the entry -- the component stays included and
    /// keeps its padding for when it contributes again.
    @objc private func componentHullToggled() {
        if case let .connectedNets(members, components, _)? = selection?.kind {
            groupHullToggled(nets: members, components: components)
            return
        }
        guard case let .component(reference)? = selection?.kind, let simulation = selectedSimulation,
              let entry = includedComponent(reference, in: simulation)
        else { return }
        entry.contributesToHull = componentHullCheckbox.state == .on
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
                // set Type to Adversarial to reveal and configure a narrowband frequency instead.
                excitation.isMain = true
                excitation.phaseDegrees = 0
                excitation.amplitude = NSNumber(value: 1)
            }
        } else if let index = excitationIndex(reference: footprintReference, pin: padNumber, in: simulation) {
            simulation.removeExcitation(at: index)
        }
    }

    @objc private func excitedToggled() {
        if case let .hullCutPort(identifier)? = selection?.kind,
           let simulation = selectedSimulation {
            if excitedCheckbox.state == .on {
                guard let port = ensureHullCutPort(identifier: identifier, in: simulation) else { return }
                port.absorbSignal = true
                port.probe = true
                if hullCutExcitationIndex(identifier: identifier, in: simulation) == nil {
                    _ = simulation.addExcitation(forHullCutPort: identifier)
                }
            } else if let index = hullCutExcitationIndex(identifier: identifier, in: simulation) {
                simulation.removeExcitation(at: index)
            }
            configurationChanged()
            return
        }
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

    @objc private func excitationTypeChanged() {
        if case let .hullCutPort(identifier)? = selection?.kind,
           let simulation = selectedSimulation,
           let excitation = hullCutExcitation(identifier: identifier, in: simulation) {
            let wasMain = excitation.isMain
            excitation.isMain = excitationTypePopUp.indexOfSelectedItem == 0
            if !excitation.isMain {
                if wasMain { excitation.hasContinuousDuration = true }
                if excitation.frequency == nil || excitation.frequency?.doubleValue == 0 {
                    excitation.frequency = NSNumber(value: document?.config.frequencyStart ?? 0)
                }
                if excitation.amplitude == nil { excitation.amplitude = NSNumber(value: 1) }
            }
            configurationChanged()
            return
        }
        guard case let .pin(reference, number)? = selection?.kind,
              let simulation = selectedSimulation,
              let excitation = excitation(reference: reference, pin: number, in: simulation)
        else { return }
        let wasMain = excitation.isMain
        excitation.isMain = excitationTypePopUp.indexOfSelectedItem == 0
        if !excitation.isMain {
            if wasMain {
                excitation.hasContinuousDuration = true
            }
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

    @objc private func durationModeChanged() {
        let continuous = durationModePopUp.indexOfSelectedItem == 0
        if case let .hullCutPort(identifier)? = selection?.kind,
           let simulation = selectedSimulation,
           let excitation = hullCutExcitation(identifier: identifier, in: simulation) {
            excitation.hasContinuousDuration = continuous
            configurationChanged()
            return
        }
        guard case let .pin(reference, number)? = selection?.kind,
              let simulation = selectedSimulation,
              let excitation = excitation(reference: reference, pin: number, in: simulation)
        else { return }
        excitation.hasContinuousDuration = continuous
        synchronizeDifferentialExcitation(from: excitation, reference: reference, pin: number)
        configurationChanged()
    }

    @objc private func excitationFieldChanged(_ sender: NSTextField) {
        if case let .hullCutPort(identifier)? = selection?.kind,
           let simulation = selectedSimulation,
           let excitation = hullCutExcitation(identifier: identifier, in: simulation) {
            switch sender {
            case phaseField: excitation.phaseDegrees = sender.doubleValue
            case relativeAmplitudeField: excitation.amplitude = NSNumber(value: sender.doubleValue)
            case frequencyField: excitation.frequency = NSNumber(value: sender.doubleValue)
            case durationField: excitation.duration = sender.doubleValue
            default: return
            }
            configurationChanged()
            return
        }
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
        case durationField:
            excitation.duration = sender.doubleValue
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
        if case let .hullCutPort(identifier)? = selection?.kind,
           let simulation = selectedSimulation,
           let port = ensureHullCutPort(identifier: identifier, in: simulation) {
            port.probe = probedCheckbox.state == .on
            configurationChanged()
            return
        }
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
        if case let .hullCutPort(identifier)? = selection?.kind,
           let simulation = selectedSimulation,
           let port = ensureHullCutPort(identifier: identifier, in: simulation) {
            port.absorbSignal = absorbingCheckbox.state == .on
            configurationChanged()
            return
        }
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
        if case let .hullCutPort(identifier)? = selection?.kind,
           let simulation = selectedSimulation,
           let port = ensureHullCutPort(identifier: identifier, in: simulation) {
            let value = max(0, pinImpedanceField.doubleValue)
            pinImpedanceField.doubleValue = value
            port.impedance = value
            configurationChanged()
            return
        }
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

    // MARK: - Board context menu

    /// The board's right-click menu for a picked net or pin. Its items mirror the Info panel's
    /// checkboxes -- reading their already-resolved state and driving their own action methods --
    /// so the menu can never disagree with the panel or skip its differential-pair mirroring.
    /// `selection` is always the current one: GeometryView picks before asking for the menu.
    private func contextMenu(for selection: GeometrySelection) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch selection.kind {
        case .net, .connectedNets:
            addNetSimulationItems(to: menu)
        case .pin, .hullCutPort:
            addPinItems(to: menu)
        case .component:
            addSelectionItems(to: menu, selection: selection)
            return menu
        }
        addSharedItems(to: menu, selection: selection)
        return menu
    }

    /// Fills the menu bar's Item menu with the pin context menu's items. Items that don't apply to
    /// the current selection (or with no selection, or the board not showing) stay, disabled.
    func populateItemMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        let isShowing = isViewLoaded && !view.isHiddenOrHasHiddenAncestor && view.window != nil
        let isNetOrPin: Bool
        switch selection?.kind {
        case .net?, .connectedNets?, .pin?, .hullCutPort?: isNetOrPin = true
        case .component?, nil: isNetOrPin = false
        }
        addPinItems(to: menu)
        let deselectAllItem = addSharedItems(to: menu, selection: selection)
        // Selecting connected or complementary items also applies to a component.
        let selectionItems = Set(menu.items.filter { $0.representedObject as? String == Self.selectionItemTag })
        for item in menu.items where !isShowing || (!isNetOrPin && !selectionItems.contains(item)) {
            item.isEnabled = false
        }
        // Escape belongs to a text field being edited (to cancel the edit), and the menu bar sees
        // key equivalents before the first responder does, so only claim it outside text editing.
        let isEditingText = view.window?.firstResponder is NSText
        deselectAllItem.isEnabled = isShowing && selection != nil && !isEditingText
    }

    /// Returns the Deselect All item, whose enabling the Item menu decides separately.
    @discardableResult
    private func addSharedItems(to menu: NSMenu, selection: GeometrySelection?) -> NSMenuItem {
        menu.addItem(.separator())
        // Like the Info panel, net items don't pick one net out of several.
        addNetGeometryItems(to: menu, netName: selectionHasMultipleNets ? "" : selection?.netName ?? "")
        return addSelectionItems(to: menu, selection: selection)
    }

    /// Marks addSelectionItems(to:selection:)'s own items, which populateItemMenu(_:) leaves
    /// enabled for a component.
    private static let selectionItemTag = "selection"

    /// The meta-network selection items, then Deselect All, which it returns.
    @discardableResult
    private func addSelectionItems(to menu: NSMenu, selection: GeometrySelection?) -> NSMenuItem {
        menu.addItem(.separator())
        let connected = ClosureMenuItem(title: "Select Connected Nets and Components", key: "u",
                                        enabled: selection.map { !seedNets(for: $0).isEmpty } ?? false) {
            [weak self] in
            guard let self, let selection else { return }
            self.selectConnectedNetsAndComponents(for: selection)
        }
        let hasComplement = selection.flatMap { complementParts(for: $0) } != nil
        // Holding Shift swaps in the variant that adds to the selection instead of replacing it.
        let complementary = ClosureMenuItem(title: complementMenuTitle(for: selection, alsoSelect: false),
                                            modifiers: [], enabled: hasComplement) {
            [weak self] in
            guard let selection else { return }
            self?.selectComplement(of: selection, alsoSelect: false)
        }
        let alsoComplementary = ClosureMenuItem(title: complementMenuTitle(for: selection, alsoSelect: true),
                                                modifiers: [.shift], enabled: hasComplement) {
            [weak self] in
            guard let selection else { return }
            self?.selectComplement(of: selection, alsoSelect: true)
        }
        alsoComplementary.isAlternate = true
        for item in [connected, complementary, alsoComplementary] {
            item.representedObject = Self.selectionItemTag
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let deselect = ClosureMenuItem(title: "Deselect All", key: "\u{1b}", modifiers: [], enabled: true) {
            [weak self] in self?.boardView.deselectAll()
        }
        menu.addItem(deselect)
        return deselect
    }

    private func addNetSimulationItems(to menu: NSMenu) {
        let included = includedCheckbox.state == .on
        menu.addItem(ClosureMenuItem(title: included ? "Remove from Simulation" : "Include in Simulation",
                                     key: "s", modifiers: [.command, .option], enabled: includedCheckbox.isEnabled) {
            [weak self] in self?.toggle(self?.includedCheckbox, #selector(WholeBoardViewController.includedToggled))
        })
        let impedance = ClosureMenuItem(title: "Impedance Probed", enabled: impedanceProbedCheckbox.isEnabled) {
            [weak self] in
            self?.toggle(self?.impedanceProbedCheckbox, #selector(WholeBoardViewController.impedanceProbedToggled))
        }
        impedance.state = impedanceProbedCheckbox.state
        menu.addItem(impedance)
    }

    private func addPinItems(to menu: NSMenu) {
        let excited = excitedCheckbox.state == .on
        menu.addItem(ClosureMenuItem(title: excited ? "Don't Excite" : "Excite", key: "e",
                                     enabled: excitedCheckbox.isEnabled) {
            [weak self] in self?.toggle(self?.excitedCheckbox, #selector(WholeBoardViewController.excitedToggled))
        })
        let isPrimary = excitationTypePopUp.indexOfSelectedItem == 0
        menu.addItem(ClosureMenuItem(title: isPrimary ? "Make Adversarial Excitation" : "Make Primary Excitation",
                                     enabled: excited && excitationTypePopUp.isEnabled) {
            [weak self] in
            guard let self else { return }
            excitationTypePopUp.selectItem(at: isPrimary ? 1 : 0)
            excitationTypeChanged()
        })
        menu.addItem(ClosureMenuItem(title: probedCheckbox.state == .on ? "Don't Probe" : "Probe",
                                     key: "p", shift: true, enabled: probedCheckbox.isEnabled) {
            [weak self] in self?.toggle(self?.probedCheckbox, #selector(WholeBoardViewController.probedToggled))
        })
        menu.addItem(ClosureMenuItem(title: absorbingCheckbox.state == .on ? "Remove Absorption" : "Add Absorption",
                                     key: "a", shift: true, enabled: absorbingCheckbox.isEnabled) {
            [weak self] in self?.toggle(self?.absorbingCheckbox, #selector(WholeBoardViewController.absorbingToggled))
        })
    }

    private func addNetGeometryItems(to menu: NSMenu, netName: String) {
        let simulation = selectedSimulation
        let canEdit = simulation != nil && !netName.isEmpty
        let contributes = simulatedCheckbox.state == .on
        menu.addItem(ClosureMenuItem(title: contributes ? "Don't Contribute to Hull" : "Contribute to Hull",
                                     key: "h", shift: true, enabled: canEdit) {
            [weak self] in self?.setContributesToHull(!contributes, netName: netName)
        })
        let isGround = simulation.map { $0.groundNetKind == .net && $0.groundNetName == netName } ?? false
        let ground = ClosureMenuItem(title: "Make Ground", key: "g", enabled: canEdit && !isGround) {
            [weak self] in self?.makeGround(netName: netName)
        }
        ground.state = isGround ? .on : .off
        menu.addItem(ground)
        let terminated = simulation?.edgeTerminatedNets.contains(netName) ?? false
        menu.addItem(ClosureMenuItem(title: terminated ? "Remove Edge Termination" : "Add Edge Termination",
                                     key: "e", shift: true, enabled: canEdit) {
            [weak self] in self?.setEdgeTerminated(!terminated, netName: netName)
        })
    }

    /// Flips a checkbox and runs its action, exactly as clicking it in the Info panel would.
    private func toggle(_ checkbox: NSButton?, _ action: Selector) {
        guard let checkbox else { return }
        checkbox.state = checkbox.state == .on ? .off : .on
        perform(action)
    }

    /// Unlike simulatedToggled(), also works on a net not yet in the simulation: contributing to
    /// the hull implies inclusion, so the menu includes it rather than offering a disabled item.
    private func setContributesToHull(_ contributes: Bool, netName: String) {
        guard let simulation = selectedSimulation, !netName.isEmpty else { return }
        if contributes {
            includeNet(named: netName, in: simulation)
        } else if let entry = involvedNet(named: netName, in: simulation) {
            entry.inclusionLevel = .geometryOnly
        } else {
            return
        }
        configurationChanged()
    }

    private func makeGround(netName: String) {
        guard let simulation = selectedSimulation, !netName.isEmpty else { return }
        simulation.groundNetKind = .net
        simulation.groundNetName = netName
        propertiesViewController.simulationEditedElsewhere()
        configurationChanged()
    }

    private func setEdgeTerminated(_ terminated: Bool, netName: String) {
        guard let simulation = selectedSimulation, !netName.isEmpty else { return }
        var nets = simulation.edgeTerminatedNets
        if terminated {
            guard !nets.contains(netName) else { return }
            nets.append(netName)
        } else {
            nets.removeAll { $0 == netName }
        }
        simulation.edgeTerminatedNets = nets
        propertiesViewController.simulationEditedElsewhere()
        configurationChanged()
    }

    /// A meta-network: a set of nets joined by 2-terminal passives (R/L/C, the same bridges the
    /// simulation turns into lumped components), and those passives.
    private struct MetaNetwork {
        var nets: Set<String> = []
        var components: Set<String> = []
    }

    /// The selected simulation's ground net(s).
    private var groundNetNames: Set<String> {
        guard let simulation = selectedSimulation, let groundName = simulation.groundNetName, !groundName.isEmpty
        else { return [] }
        switch simulation.groundNetKind {
        case .net: return [groundName]
        case .netClass: return netsByNetClass[groundName] ?? []
        default: return []
        }
    }

    /// Two-pin passives keyed by each of their (distinct, connected) nets.
    private func passivesByNet() -> [String: [KicadFootprintInfo]] {
        var result: [String: [KicadFootprintInfo]] = [:]
        for footprint in allFootprints where footprint.pins.count == 2 && isPassive(reference: footprint.reference) {
            let first = footprint.pins[0].netName
            let second = footprint.pins[1].netName
            guard !first.isEmpty, !second.isEmpty, first != second else { continue }
            result[first, default: []].append(footprint)
            result[second, default: []].append(footprint)
        }
        return result
    }

    /// Everything passively connected to `netName`. Ground is neither walked through nor included
    /// -- nearly every shunt part lands there, so crossing it would take in most of the board --
    /// though the passives reaching it are. A walk starting on ground walks out from it.
    private func metaNetwork(from netName: String) -> MetaNetwork {
        let groundNets = groundNetNames
        let passives = passivesByNet()
        var network = MetaNetwork(nets: [netName])
        var frontier = [netName]
        while let net = frontier.popLast() {
            for passive in passives[net] ?? [] {
                network.components.insert(passive.reference)
                for pin in passive.pins where pin.netName != net && !groundNets.contains(pin.netName) {
                    if network.nets.insert(pin.netName).inserted { frontier.append(pin.netName) }
                }
            }
        }
        return network
    }

    /// The nets a selection grows its meta-network from.
    private func seedNets(for selection: GeometrySelection) -> [String] {
        switch selection.kind {
        case .net, .pin, .hullCutPort:
            return selection.netName.map { $0.isEmpty ? [] : [$0] } ?? []
        case let .connectedNets(members, components, pins):
            let ground = groundNetNames
            let componentNets = components.flatMap { reference in
                allFootprints.first { $0.reference == reference }?.pins.map(\.netName) ?? []
            }
            let all = members + pins.compactMap(\.net) + componentNets
            var seen = Set<String>()
            return all.filter { !$0.isEmpty && !ground.contains($0) && seen.insert($0).inserted }
        case let .component(reference):
            let ground = groundNetNames
            let nets = allFootprints.first { $0.reference == reference }?.pins.map(\.netName) ?? []
            let signal = nets.filter { !$0.isEmpty && !ground.contains($0) }
            return signal.isEmpty ? nets.filter { !$0.isEmpty } : signal
        }
    }

    private func selectConnectedNetsAndComponents(for selection: GeometrySelection) {
        var network = MetaNetwork()
        for net in seedNets(for: selection) {
            let grown = metaNetwork(from: net)
            network.nets.formUnion(grown.nets)
            network.components.formUnion(grown.components)
        }
        if case let .component(reference) = selection.kind { network.components.insert(reference) }
        guard let origin = selection.netName.flatMap({ $0.isEmpty ? nil : $0 }) ?? network.nets.sorted().first
        else { return }
        boardView.selectNets(NetNameFormatting.sortedForDisplay(Array(network.nets)),
                             components: network.components.sorted(), origin: origin)
    }

    // MARK: - Complementary selection
    //
    // A differential pair's two halves are mirror-image meta-networks: the same passives, with the
    // same values, in the same places. The complement of a selection is its counterpart there.

    /// How one half of a differential pair's meta-network corresponds to the other.
    private struct ComplementMapping {
        var nets: [String: String] = [:]
        var components: [String: String] = [:]
    }

    /// Pairs the meta-network containing `netName` with its complement. The two are seeded by
    /// DifferentialPairNetHeuristic's name match on any of their nets, then walked in parallel:
    /// passives on corresponding nets correspond when they have the same kind and value, and lead to
    /// ground or not alike, and the nets on their far sides then correspond too.
    /// Corresponding nets the walk doesn't reach fall back to the name heuristic.
    private func complementMapping(containing netName: String) -> ComplementMapping? {
        let network = metaNetwork(from: netName)
        guard let (seed, partnerSeed) = network.nets.sorted().lazy.compactMap({ net -> (String, String)? in
            guard let partner = self.differentialPairPartnerNetName(for: net), !network.nets.contains(partner)
            else { return nil }
            return (net, partner)
        }).first else { return nil }
        let partnerNetwork = metaNetwork(from: partnerSeed)
        guard partnerNetwork.nets.isDisjoint(with: network.nets) else { return nil }

        let ground = groundNetNames
        let passives = passivesByNet()
        // Pin numbers aren't compared: a mirrored layout often turns the same part round.
        struct Key: Hashable { let kind: String, value: String, toGround: Bool }
        func key(_ passive: KicadFootprintInfo, on net: String) -> Key {
            let other = passive.pins.first { $0.netName != net }?.netName ?? ""
            return Key(kind: String(passive.reference.prefix { $0.isLetter }).uppercased(),
                       value: passive.value, toGround: ground.contains(other))
        }

        var mapping = ComplementMapping(nets: [seed: partnerSeed])
        var mappedPartners: Set<String> = [partnerSeed]
        var queue = [(seed, partnerSeed)]
        while let (net, partner) = queue.popLast() {
            var candidates = (passives[partner] ?? []).filter { !mapping.components.values.contains($0.reference) }
                .sorted { $0.reference < $1.reference }
            for passive in (passives[net] ?? []).sorted(by: { $0.reference < $1.reference })
            where mapping.components[passive.reference] == nil && network.components.contains(passive.reference) {
                let wanted = key(passive, on: net)
                guard let index = candidates.firstIndex(where: { key($0, on: partner) == wanted }) else { continue }
                let counterpart = candidates.remove(at: index)
                mapping.components[passive.reference] = counterpart.reference
                guard let far = passive.pins.first(where: { $0.netName != net })?.netName,
                      let partnerFar = counterpart.pins.first(where: { $0.netName != partner })?.netName,
                      !ground.contains(far), mapping.nets[far] == nil, !mappedPartners.contains(partnerFar)
                else { continue }
                mapping.nets[far] = partnerFar
                mappedPartners.insert(partnerFar)
                queue.append((far, partnerFar))
            }
        }
        for net in network.nets where mapping.nets[net] == nil {
            if let partner = differentialPairPartnerNetName(for: net), partnerNetwork.nets.contains(partner),
               !mappedPartners.contains(partner) {
                mapping.nets[net] = partner
                mappedPartners.insert(partner)
            }
        }
        return mapping
    }

    /// The individual nets, components and pins a selection is made of.
    private struct SelectionParts {
        var nets: [String] = []
        var components: [String] = []
        var pins: [BoardPinRef] = []

        var isEmpty: Bool { nets.isEmpty && components.isEmpty && pins.isEmpty }

        mutating func formUnion(_ other: SelectionParts) {
            nets += other.nets.filter { !nets.contains($0) }
            components += other.components.filter { !components.contains($0) }
            pins += other.pins.filter { !pins.contains($0) }
        }
    }

    private func parts(of selection: GeometrySelection) -> SelectionParts {
        switch selection.kind {
        case .net:
            return SelectionParts(nets: selection.netName.map { [$0] } ?? [])
        case let .pin(reference, number):
            return SelectionParts(pins: [BoardPinRef(reference: reference, number: number, net: selection.netName)])
        case let .component(reference):
            return SelectionParts(components: [reference])
        case let .connectedNets(members, components, pins):
            return SelectionParts(nets: members, components: components, pins: pins)
        case .hullCutPort:
            return SelectionParts()
        }
    }

    /// The board target selecting exactly `parts`: a single part on its own, otherwise a group.
    private func target(selecting parts: SelectionParts, origin: String?) -> BoardPickTarget? {
        switch (parts.nets.count, parts.components.count, parts.pins.count) {
        case (0, 0, 0): return nil
        case (1, 0, 0): return .net(parts.nets[0])
        case (0, 1, 0): return .component(parts.components[0])
        case (0, 0, 1):
            let pin = parts.pins[0]
            return .pin(reference: pin.reference, number: pin.number, net: pin.net)
        default:
            let nets = NetNameFormatting.sortedForDisplay(parts.nets)
            return .nets(origin: origin ?? nets.first ?? parts.pins.first?.net ?? "", members: nets,
                         components: parts.components.sorted(), pins: parts.pins)
        }
    }

    /// The pin mirroring `pin`: on the corresponding passive, the pin on the corresponding net (or
    /// on ground, for a pin on ground); on any other part (a connector carrying both halves, say),
    /// that same part's pin on the corresponding net.
    private func complementPin(_ pin: BoardPinRef, mapping: ComplementMapping) -> BoardPinRef? {
        let net = pin.net ?? ""
        let ground = groundNetNames
        let reference = mapping.components[pin.reference] ?? pin.reference
        if mapping.components[pin.reference] == nil && mapping.nets[net] == nil { return nil }
        let pins = allFootprints.first { $0.reference == reference }?.pins ?? []
        let match = mapping.nets[net].flatMap { partnerNet in pins.first { $0.netName == partnerNet } }
            ?? (ground.contains(net) && reference != pin.reference ? pins.first { ground.contains($0.netName) } : nil)
        return match.map { BoardPinRef(reference: reference, number: $0.number, net: $0.netName) }
    }

    /// Every part of `selection`'s complement, or nil if none of it has one. Each meta-network the
    /// selection touches is mapped onto its own complement.
    private func complementParts(for selection: GeometrySelection) -> SelectionParts? {
        var mapping = ComplementMapping()
        var covered = Set<String>()
        for net in seedNets(for: selection) where !covered.contains(net) {
            covered.formUnion(metaNetwork(from: net).nets)
            guard let found = complementMapping(containing: net) else { continue }
            mapping.nets.merge(found.nets) { first, _ in first }
            mapping.components.merge(found.components) { first, _ in first }
        }
        let source = parts(of: selection)
        let result = SelectionParts(nets: source.nets.compactMap { mapping.nets[$0] },
                                    components: source.components.compactMap { mapping.components[$0] },
                                    pins: source.pins.compactMap { complementPin($0, mapping: mapping) })
        return result.isEmpty ? nil : result
    }

    /// Replaces the selection with its complement, or (`alsoSelect`) adds the complement to it.
    private func selectComplement(of selection: GeometrySelection, alsoSelect: Bool) {
        guard var result = complementParts(for: selection) else { return }
        if alsoSelect {
            var combined = parts(of: selection)
            combined.formUnion(result)
            result = combined
        }
        if let target = target(selecting: result, origin: alsoSelect ? selection.netName : nil) {
            boardView.select(target)
        }
    }

    private func complementMenuTitle(for selection: GeometrySelection?, alsoSelect: Bool) -> String {
        let noun: String
        switch selection?.kind {
        case .pin?: noun = "Pin"
        case .net?: noun = "Net"
        case .component?: noun = "Component"
        case .connectedNets?: noun = "Parts"
        case .hullCutPort?, nil: noun = ""
        }
        let title = alsoSelect ? "Also Select Complementary" : "Select Complementary"
        return noun.isEmpty ? title : "\(title) \(noun)"
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
        guard let document, let board = document.board else { return false }
        let kicadPcbPath = board.kicadPcbPath
        guard loadedForPath != kicadPcbPath else { return false }
        loadedForPath = kicadPcbPath
        stitchingViaPlanInputsKey = nil
        // References are only meaningful on the board they came from.
        unsupportedSimModelReasons = [:]
        simModelLoadError = nil
        simModelsLoaded = false
        layerGeometryLoader?.cancel()
        layerGeometryLoader = nil
        onLoadingStateChanged?(true)
        // Publish the cheap KiCad layer catalog first. The visible setup layers are then generated
        // first; every other layer trickles in behind them without holding the screen hostage.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let catalog: EMSGeometryPreview?
            let loadError: Error?
            do {
                catalog = try board.layerCatalogPreview(forWholeBoard: true)
                loadError = nil
            } catch {
                catalog = nil
                loadError = error
            }
            DispatchQueue.main.async {
                guard let self, self.loadedForPath == kicadPcbPath else { return }
                guard let catalog else {
                    // A linked board can disappear, become unreadable, or live on an unavailable
                    // volume between document saves. Keep the path retryable and surface the
                    // NSError returned by libkicad instead of presenting a permanently blank view.
                    self.loadedForPath = nil
                    self.onLoadingStateChanged?(false)
                    if let loadError { NSApp.presentError(loadError) }
                    return
                }
                self.boardView.preview = catalog
                self.loadBoardGeometry(for: board, catalog: catalog)
                self.refreshStitchingViaPlan()
            }
        }
        return true
    }

    /// Copper comes only from the detailed whole-board build (net-grouped, unioned, drilled), which
    /// starts immediately; there is no rough per-polygon copper pass for it to replace. The
    /// non-copper layers load alongside it through the layer loader, visible ones first.
    private func loadBoardGeometry(for board: KicadBoardBridge, catalog: EMSGeometryPreview) {
        let kicadPcbPath = board.kicadPcbPath
        let finished = DispatchGroup()
        // Phases of the initial board load, visible in Instruments' os_signpost track.
        let signposter = OSSignposter(subsystem: "com.kiems", category: "BoardLoad")
        let wholeLoad = signposter.beginInterval("Board load")

        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detailedSignpost = signposter.beginInterval("Detailed board build")
            let detailed = try? board.wholeBoardPreview()
            let footprints = (try? board.footprints()) ?? []
            signposter.endInterval("Detailed board build", detailedSignpost)
            DispatchQueue.main.async {
                defer { finished.leave() }
                guard let self, self.loadedForPath == kicadPcbPath else { return }
                self.allFootprints = footprints
                self.updateSimModelReasons()
                self.refreshActivityHighlight()
                if let detailed, let preview = self.boardView.preview {
                    preview.mergeLoadedPreview(detailed)
                    self.boardView.refreshLoadedGeometry()
                }
            }
        }

        // Resolving models reads the schematic, which the board doesn't need, so the board is
        // shown without waiting for it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reasons: [String: String]
            let loadError: String?
            do {
                let models = try board.componentSimModels()
                reasons = Dictionary(models.filter { !$0.supported }.map { ($0.reference, $0.reason) },
                                     uniquingKeysWith: { first, _ in first })
                loadError = nil
            } catch {
                reasons = [:]
                loadError = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self, self.loadedForPath == kicadPcbPath else { return }
                self.unsupportedSimModelReasons = reasons
                self.simModelLoadError = loadError
                self.simModelsLoaded = true
                self.updateSimModelReasons()
            }
        }

        finished.enter()
        let loaderSignpost = signposter.beginInterval("Other layers")
        let loader = BoardLayerGeometryLoader(board: board, preview: catalog, view: boardView,
                                               initiallyVisible: boardView.visibleLayerNames,
                                               excluding: { $0.hasSuffix(".Cu") }) {
            signposter.endInterval("Other layers", loaderSignpost)
            finished.leave()
        }
        layerGeometryLoader = loader
        loader.start()

        // The main-pane spinner stays up until every layer has loaded and been built into the
        // board's geometry, so the board is never shown partially loaded.
        finished.notify(queue: .main) { [weak self] in
            let geometrySignpost = signposter.beginInterval("Waiting for current geometry")
            self?.boardView.whenBoardGeometryCurrent { [weak self] in
                signposter.endInterval("Waiting for current geometry", geometrySignpost)
                signposter.endInterval("Board load", wholeLoad)
                guard let self, self.loadedForPath == kicadPcbPath else { return }
                self.onLoadingStateChanged?(false)
            }
        }
    }

    /// Refreshes the Info panel's component controls, which depend on each component's SPICE model.
    /// A schematic that couldn't be read leaves every footprint without a model.
    private func updateSimModelReasons() {
        if let simModelLoadError {
            let reason = "Couldn't read the schematic: \(simModelLoadError)"
            unsupportedSimModelReasons = Dictionary(allFootprints.map { ($0.reference, reason) },
                                                    uniquingKeysWith: { first, _ in first })
        }
        updateConfigurationControls()
    }

    /// Forces the next refresh() call to actually re-query the board, rather than treating it as
    /// already loaded -- see DocumentWindowController.handleLinkedKicadFilesChanged.
    func invalidate() {
        layerGeometryLoader?.cancel()
        layerGeometryLoader = nil
        loadedForPath = nil
        // The board itself changed on disk: the same settings can now give a different plan.
        stitchingViaPlanInputsKey = nil
        netClassByNet.removeAll()
        netsByNetClass.removeAll()
        resolvingActivityNetClasses.removeAll()
        selectedNetClassName = nil
        selectedNetClassIsMultiple = false
        isLoadingSelectedNetClass = false
    }
}

/// A context-menu item that runs a closure, so each item can capture the net/pin it was built for.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, key: String = "", shift: Bool = false, modifiers: NSEvent.ModifierFlags? = nil,
         enabled: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers ?? (shift ? [.command, .shift] : [.command])
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
