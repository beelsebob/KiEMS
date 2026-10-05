import Cocoa
import os

/// One row in the source list. A plain reference type (NSOutlineView needs stable item identity
/// for expand/collapse state) wrapping which kind of thing it represents.
final class SourceListNode: NSObject {
    enum Kind {
        case netClass(String)
        case net(String)
        case footprint(KicadFootprintInfo)
        /// A single pin under a footprint parent node. Each pin toggles its own single-pin
        /// InvolvedNetConfig entry -- a v1 simplification; InvolvedNetConfig's pins() list can hold
        /// more than one, but the source list only ever creates/matches one-pin entries. Someone
        /// wanting a combined multi-pin entry can still hand-edit the saved JSON.
        case pin(footprintReference: String, pin: KicadFootprintPin)
        /// A pure grouping row with no InvolvedNetConfig identity of its own -- a component category
        /// (e.g. "Capacitors") in Footprint/Pin mode, or a hierarchical-sheet path segment (e.g.
        /// "MCU") in Net mode. See SourceListViewController.ComponentCategory/hierarchicalNetNodes.
        case group(String)
    }

    let kind: Kind
    var children: [SourceListNode] = []

    /// Overrides `title` below -- used for a hierarchical net-name leaf (see
    /// SourceListViewController.hierarchicalNetNodes), which needs to display just its last path
    /// segment (e.g. "En") while `kind` keeps the full original net name (e.g. "/MCU/DS1/En") for
    /// matching/storage, since nothing about involvedNets()/KicadBoardBridge understands hierarchy.
    var displayTitleOverride: String?

    init(kind: Kind) {
        self.kind = kind
    }

    var title: String {
        if let displayTitleOverride { return displayTitleOverride }
        switch kind {
        case .netClass(let name): return name
        case .net(let name): return name
        case .footprint(let info): return info.value.isEmpty ? info.reference : "\(info.reference) (\(info.value))"
        case .group(let name): return name
        case .pin(_, let pin):
            let function = Self.strippingTrailingNumericSuffix(pin.function)
            return function.isEmpty ? pin.number : "\(pin.number) (\(function))"
        }
    }

    /// KiCad often auto-suffixes a pin's schematic-level function name with its own pad number to
    /// keep otherwise-identical function names unique within a footprint -- e.g. a MOSFET array's
    /// four drain pads (numbers 5-8) show up with pin *function* "Drain_5"/"Drain_6"/"Drain_7"/
    /// "Drain_8". Redundant once the pad's own number is already shown right alongside it (see
    /// `title` above), so stripped for display -- the raw, unstripped value (still on `pin.function`)
    /// is untouched, since nothing besides display needs it.
    static func strippingTrailingNumericSuffix(_ text: String) -> String {
        guard let underscoreIndex = text.lastIndex(of: "_") else { return text }
        let suffix = text[text.index(after: underscoreIndex)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return text }
        return String(text[..<underscoreIndex])
    }

    /// False for a bare footprint node (not a specific pin) or a pure grouping row -- there's
    /// nothing to toggle "included in simulation" or "excited in simulation" for the footprint
    /// itself, or for a group. True for every other kind, including `.pin` -- even though "included"
    /// resolves to that pin's *net* (see SourceListViewController.matchingEntryIndex), a pin still
    /// has its own identity to select/show detail for (not least because "excited" really is
    /// per-pin).
    var isSelectableForInclusion: Bool {
        switch kind {
        case .netClass, .net, .pin: return true
        case .footprint, .group: return false
        }
    }
}

/// A plain NSView that also responds to a click anywhere within its bounds -- used for
/// SourceListViewController's scope header, which behaves as one big clickable control (not a
/// small button within it) that pops up a menu of Net Class/Net/Footprint, table-header style.
private final class ClickableHeaderView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A row's status icon (see SourceListViewController.icon(for:)), or nothing for a row with none.
/// Its own NSOutlineView column (SourceListViewController's iconColumn), separate from
/// NetNameCellView's text column -- an earlier version of this drew the icon in a floating overlay
/// positioned outside the outline view instead, specifically to keep it visible even when the text
/// column scrolled horizontally, but nothing there drew outlineView's own row-selection highlight,
/// so a selected row's icon (tinted white to match) went invisible against the overlay's plain
/// backdrop, and manually re-deriving "is this row selected, and is the window key" to paint a
/// matching highlight by hand never quite tracked the real thing -- wrong colors under some
/// combination of focus/selection state were exactly the bug that sent this back to a real column.
/// NSTableRowView already draws the correct highlight behind every column's cell in a selected row,
/// this one included, so nothing extra is needed here for that.
private final class SourceListIconCellView: NSTableCellView {
    private static let iconExtent: CGFloat = 14
    private static let trailingInset: CGFloat = 4

    private let iconImageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    // Frame-based, not Auto Layout -- matches NetNameCellView's own manually-positioned content
    // (see its doc comment): a fixed square, right-inset and vertically centered, is simpler to get
    // right this way than fighting NSTableCellView/NSImageView's own layout machinery for it.
    private func setUp() {
        iconImageView.imageScaling = .scaleProportionallyDown
        // Set up front, not left to backgroundStyle's didSet alone -- that only fires once
        // NSTableRowView actually assigns a backgroundStyle, which may be after the first draw.
        iconImageView.contentTintColor = .secondaryLabelColor
        addSubview(iconImageView)
    }

    override func layout() {
        super.layout()
        let extent = Self.iconExtent
        iconImageView.frame = NSRect(
            x: bounds.width - extent - Self.trailingInset, y: (bounds.height - extent) / 2,
            width: extent, height: extent)
    }

    func configure(icon: String?) {
        iconImageView.image = icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        iconImageView.isHidden = icon == nil
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            iconImageView.contentTintColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor
        }
    }
}

/// The "source list" (Net Class / Net / Footprint browser) and its right-hand detail pane, editing
/// involvedNets() membership for whichever simulation SimulationListViewController has selected
/// (see setSelectedSimulationIndex).
final class SourceListViewController: NSViewController {
    private weak var document: Document?
    private var selectedIndex: Int?

    /// Fired whenever the selected simulation's involvedNets()/excitations() membership changes (see
    /// includedToggled/excitedToggled/excitationTypeChanged) -- DocumentWindowController wires this
    /// to InvolvedNetsViewController.refresh(), which has no other way to learn that its own summary
    /// table (nets *and* which of their pins are excited) is now stale.
    var onInvolvedNetsChanged: (() -> Void)?

    private let scopeHeaderView = ClickableHeaderView()
    private let scopeTitleLabel = NSTextField(labelWithString: "")
    private let scopeDisclosureImageView = NSImageView()
    private let outlineView = NSOutlineView()
    private let scroll = NSScrollView()
    // The source-list/detail divider -- lets the user drag to resize the source list. Stored (rather
    // than a local in buildUI) so viewDidLayout can set its initial position once the view actually
    // has a frame to compute against; NSSplitView has no "set this before layout" API otherwise.
    private var sourceSplitView: NSSplitView!
    private var didSetInitialSplitPosition = false
    // Titles are added separately as their own NSTextField, not via checkboxWithTitle: -- see
    // checkboxRow(_:title:).
    // Shown only for a .net/.netClass selection -- see probeCheckbox/absorbCheckbox below for the
    // per-pin equivalent (a .pin node no longer has an "included" checkbox of its own at all).
    // Titled "Simulation Net" -- full participation: grows the hull, gets probe/absorb/excite ports.
    // Mutually exclusive with geometryOnlyCheckbox below (both ultimately just read/write the same
    // underlying EMSInvolvedNetBridge.inclusionLevel -- see includedToggled()/geometryOnlyToggled()).
    private let includedCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    // Titled "Included in Simulation" -- the narrower tier (kiems::NetInclusionLevel::
    // GeometryOnly): the net's own copper physically exists in the simulated geometry/mesh (clipped
    // to whatever hull the Simulation Net-level nets already produced, and densified the same
    // edge-aware way -- see grid_gen.cpp), but never grows the hull itself and is never eligible for
    // probe/absorb/excite ports. Meant for things like via-stitched ground-adjacent structure that
    // needs to physically exist in the model without itself being probed or driven.
    private let geometryOnlyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    // Shown only for a .net/.netClass selection, directly under includedCheckbox, and only once
    // it's checked (see updateValueFieldsVisibility()) -- a net-level, auto-placed, non-loading
    // impedance-measurement probe, independent of whatever ports this net's own pins resolve to.
    // See kiems::InvolvedNetConfig::probeImpedance()'s own doc comment.
    private let probeImpedanceCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let simulateAsDifferentialPairCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    // Shown only for a .pin selection. Independent of excitedCheckbox (see its own declaration
    // comment) -- checking either one auto-includes this pin's net, same as includedCheckbox does
    // for a net/net-class row. absorbCheckbox is only shown (and only meaningful) once probeCheckbox
    // is checked -- see InvolvedNetConfig::ProbedPin's own doc comment for what the two together
    // mean physically: Probe+Absorb Signal reproduces today's default port behavior (a real,
    // matched-impedance termination); Probe alone is a genuinely passive, non-loading read point.
    private let probeCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let absorbCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let impedanceField = NSTextField(string: "")
    private let planeComboBox = NSComboBox()
    private let widthField = NSTextField(string: "")
    private let dBMarginField = NSTextField(string: "")
    private let directionPopUp = NSPopUpButton()
    private let customDirectionField = NSTextField(string: "")
    // Only meaningful (and only ever shown) for a .pin node -- a per-pad escape hatch on top of
    // directionPopUp/customDirectionField's own net-wide value, for when opposite ends of a routed
    // net depart their own pads in different cardinal directions and one net-wide value can't be
    // right for both. See kiems::PinDirectionOverride's own doc comment.
    private let pinDirectionOverridePopUp = NSPopUpButton()
    private let pinDirectionOverrideCustomField = NSTextField(string: "")
    private var pinDirectionOverrideRow: NSView!
    // Styled like DocumentWindowController's noSelectionLabel ("No Simulation Selected") -- same
    // "big, muted placeholder text" look for the same kind of "nothing to show here yet" state.
    private let detailStatusLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Select a net, net class, or pin.")
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.textColor = .tertiaryLabelColor
        return label
    }()

    // Each gets its own formatter instance -- see MicrometerValueFormatter's own doc comment on why
    // (the displayed/accepted unit is sticky per-instance state, so sharing one across fields would
    // make them all switch units together).
    private let impedanceFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Ω", acceptedSuffixes: ["ohms", "ohm", "Ω"])
    private let widthFormatter = MicrometerValueFormatter()

    // A horizontal rule before the excitation editor, inset the same way includedCheckbox/
    // excitedCheckbox are (see insetRow) -- hidden/shown in lockstep with excitedCheckbox, since
    // there's no point ruling off a section that isn't showing.
    private let excitationSeparator = NSView()

    // "Width override"/"dB margin override" hide behind this disclosure, the same pattern
    // SimulationPropertiesViewController uses for its own via-settings advanced row.
    private let widthDBAdvancedDisclosureButton = NSButton()
    private var widthDBAdvancedRow: NSStackView!
    private var widthDBAdvancedRowExpanded = false

    // The rows wrapping includedCheckbox/excitedCheckbox/excitationSeparator (see insetRow/
    // checkboxRow) -- hiding a control nested inside a plain NSView doesn't shrink that NSView's own
    // reserved space in detailStack, so show/hide has to target these actual arranged subviews
    // instead.
    private var includedRow: NSView!
    private var geometryOnlyRow: NSView!
    private var probeImpedanceRow: NSView!
    private var simulateAsDifferentialPairRow: NSView!
    private var probeRow: NSView!
    private var absorbRow: NSView!
    private var excitedRow: NSView!
    private var excitationSeparatorRow: NSView!
    private var impedanceRow: NSView!
    // The Impedance/Reference Plane rows -- hidden as a group whenever includedCheckbox isn't
    // checked (see updateValueFieldsVisibility). widthDBAdvancedRow is handled alongside them but
    // separately, since it also depends on widthDBAdvancedRowExpanded.
    private var valueFieldRows: [NSView] = []

    // Excitation editor -- only ever shown for a pin-level selection (ExcitationConfig is
    // inherently per footprint+pin, not per net/net-class; see kiems::ExcitationConfig).
    // Independent of probeCheckbox -- available whether or not Probe is checked; checking it always
    // yields the same full absorbing-port structure Probe+Absorb Signal does, regardless of this
    // pin's own probe/absorb state (see PortConfig::absorbSignal()'s own doc comment).
    private let excitedCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// Primary (item 0) = a main excitation (isMain); Adversarial (item 1) = a non-main tone burst.
    private let excitationTypePopUp = NSPopUpButton()
    private let startTimeField = NSTextField(string: "")
    private let durationField = NSTextField(string: "")
    /// Adversarial only: Continuous (item 0) or Limited (item 1) -- see
    /// EMSExcitationBridge.hasContinuousDuration. durationField is then shown only for Limited.
    private let durationModePopUp = NSPopUpButton()
    private var durationModeRow: NSView!
    private var durationRow: NSStackView!
    private let phaseField = NSTextField(string: "")
    private let frequencyField = NSTextField(string: "")
    private let amplitudeField = NSTextField(string: "")
    // One instance each -- see MicrometerValueFormatter's doc comment on why (sticky per-instance
    // unit state; startTime/duration share a unit that never varies, but phase's does).
    private let startTimeFormatter = UnitSuffixValueFormatter(
        displaySuffix: "s", acceptedSuffixes: ["seconds", "second", "secs", "sec", "s"])
    private let durationFormatter = UnitSuffixValueFormatter(
        displaySuffix: "s", acceptedSuffixes: ["seconds", "second", "secs", "sec", "s"])
    private let frequencyFormatter = UnitSuffixValueFormatter(
        displaySuffix: "Hz", acceptedSuffixes: ["hertz", "hz"], autoSelectsSIPrefix: true)
    private let phaseFormatter = PhaseValueFormatter()
    private var excitationFieldsContainer: NSStackView!
    /// Hidden for a main excitation -- see populateExcitationFields(from:)'s own comment on why
    /// frequency (unlike amplitude, see amplitudeField's own row) has no meaning there.
    private var frequencyOnlyRows: [NSView] = []

    private var rootNodes: [SourceListNode] = []
    private var selectedNode: SourceListNode?
    /// Every footprint (with its own pins already populated) refreshBoardData() last fetched, in
    /// whichever scope actually queries it (.net and .footprint both do; .netClass doesn't, but
    /// nothing needs this while browsing net classes -- see offerDifferentialPairMirror's own doc
    /// comment). Kept around specifically so a differential-pair partner lookup doesn't need its
    /// own separate, redundant KicadBoardBridge round trip.
    private var allFootprints: [KicadFootprintInfo] = []
    /// Set by refreshBoardData() whenever the current scope's KicadBoardBridge query threw, so
    /// showDetail(for: nil) can show *why* the list is empty (or incomplete) instead of the generic
    /// "select something" placeholder, which used to look identical to a query that genuinely
    /// succeeded with zero results.
    private var boardDataError: String?

    /// The choices in directionPopUp. North/South/East/West are fixed cardinal angles, matching
    /// GeometryView's board-space convention (+X east/right, +Y north/up -- see its own isFlipped
    /// doc comment). `custom` reveals customDirectionField for any other angle; `auto` clears the
    /// override entirely, letting port_resolution.cpp fall back to the pad's own real rotation
    /// (not a value derived from routed copper -- a pad with traces entering from more than one
    /// side has no single departure direction to derive in the first place, but its own physical
    /// rotation is always well-defined regardless of how many traces connect to it).
    private enum DirectionKind: Int, CaseIterable {
        case auto, north, south, east, west, custom

        var title: String {
            switch self {
            case .auto: return "Auto"
            case .north: return "North"
            case .south: return "South"
            case .east: return "East"
            case .west: return "West"
            case .custom: return "Custom"
            }
        }

        /// The fixed angle (degrees) for every case but .custom, whose angle instead comes from
        /// customDirectionField -- and .auto, which has none at all (nil override).
        var fixedDegrees: Double? {
            switch self {
            case .auto, .custom: return nil
            case .north: return 90
            case .south: return 270
            case .east: return 0
            case .west: return 180
            }
        }

        /// Classifies a stored direction value (nil, or InvolvedNetConfig::direction()'s degrees)
        /// back into one of these cases -- a fixed angle that happens to equal one of the cardinal
        /// values reads back as that cardinal, not Custom, so re-opening a net set to due north still
        /// shows "North" rather than "Custom (90°)".
        static func kind(for direction: Double?) -> DirectionKind {
            guard let direction else { return .auto }
            for kind in DirectionKind.allCases where kind.fixedDegrees == direction {
                return kind
            }
            return .custom
        }
    }

    private enum Scope: Int { case netClass, net, footprint }
    private var scope: Scope = .footprint
    private static let scopeTitles = ["Net Class", "Net", "Footprint/Pin"]

    private static let mainColumnIdentifier = NSUserInterfaceItemIdentifier("main")
    private static let iconColumnIdentifier = NSUserInterfaceItemIdentifier("icon")
    private static let iconColumnWidth: CGFloat = 20

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
    }

    private func buildUI() {
        scopeTitleLabel.stringValue = Self.scopeTitles[scope.rawValue]
        scopeTitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        scopeTitleLabel.textColor = .headerTextColor
        scopeTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        scopeDisclosureImageView.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Choose what to browse by")
        scopeDisclosureImageView.contentTintColor = .headerTextColor
        scopeDisclosureImageView.translatesAutoresizingMaskIntoConstraints = false

        scopeHeaderView.translatesAutoresizingMaskIntoConstraints = false
        scopeHeaderView.onClick = { [weak self] in self?.showScopeMenu() }

        let column = NSTableColumn(identifier: Self.mainColumnIdentifier)
        column.title = "Source"
        column.width = 220
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        // A separate, fixed-width column for the row's status icon (see icon(for:)) -- added after
        // (so it's rightmost) and never resized. Unlike the outline (tree) column, an ordinary table
        // column isn't indented per row, and -- the actual point of it being a real column rather
        // than an overlay drawn on top -- NSTableRowView draws the correct native selection
        // highlight behind it automatically, in every focus/selection state, matching the text
        // column beside it exactly.
        let iconColumn = NSTableColumn(identifier: Self.iconColumnIdentifier)
        iconColumn.title = ""
        iconColumn.width = Self.iconColumnWidth
        iconColumn.minWidth = Self.iconColumnWidth
        iconColumn.maxWidth = Self.iconColumnWidth
        iconColumn.resizingMask = []
        outlineView.addTableColumn(iconColumn)

        outlineView.headerView = nil
        // No header for the user to drag a column by, so reordering could only ever happen
        // programmatically -- disabled anyway, so the icon column can't end up anywhere but rightmost.
        outlineView.allowsColumnReordering = false
        // Only the text column (the first) grows/shrinks as the pane resizes; iconColumn stays fixed
        // (min==max above), so it's always flush against the pane's actual right edge, regardless of
        // how wide that pane is. This replaces an earlier version that instead sized the text column
        // to fit its widest row and let a horizontal scroller reveal the rest -- which meant the icon
        // column, being part of the same scrollable content, could scroll out of view right along
        // with a long name. A long name now just clips within its own column's width instead (AppKit
        // already clips a view's own drawing to its bounds, so this needs nothing extra) -- the
        // tradeoff accepted for "icons always on the right, no matter the column size." Needs
        // outlineView.autoresizingMask below (not an Auto Layout constraint) to actually fire on
        // resize -- see that property's own comment.
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.delegate = self
        outlineView.dataSource = self
        // Not target/action -- outlineViewSelectionDidChange(_:) below, a genuine selection-change
        // notification, fires reliably for keyboard (arrow-key) navigation too. action only reliably
        // fires for mouse clicks, which left the detail pane on the right stale after using the
        // keyboard to move through the list.

        // NSTableView's own column-autoresizing logic (columnAutoresizingStyle above) hooks into the
        // classic pre-Auto-Layout resize chain (resizeSubviews(withOldSize:), driven by
        // autoresizingMask), not into Auto Layout constraints -- so outlineView needs to keep
        // translatesAutoresizingMaskIntoConstraints at its default `true` and an explicit .width mask
        // here, letting NSScrollView's own standard (and, for exactly this reason, autoresizing-mask-
        // based) "no horizontal scroller -> document view tracks the clip view's width" mechanism
        // drive it, rather than pinning its width with a constraint of our own (which starts
        // reporting a frame width just as valid-looking, but never triggers columnAutoresizingStyle's
        // recompute at all, silently reverting the icon column to scrolling with the text again).
        outlineView.autoresizingMask = [.width]

        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        // No horizontal scroller -- the text column no longer ever grows past what's visible (see
        // columnAutoresizingStyle above), so there's nothing for it to scroll to. This is also what
        // makes NSScrollView actually engage its own width-tracking for the document view (see
        // outlineView.autoresizingMask above).
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // No fixed width or height -- stretches to fill leftColumn's full available size (leftColumn
        // itself is now stretched to the source-list pane's size by sourceSplitView, see below).

        // A flat tinted bar with a hard bottom edge -- the same "header" look
        // DocumentWindowController's project/board picker bar uses -- so the scope selector reads
        // as an actual table header for the outline view below it: a plain label plus a disclosure
        // chevron, the whole bar clickable (not a control that looks like a floating popup button).
        scopeHeaderView.wantsLayer = true
        scopeHeaderView.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.15).cgColor

        let scopeHeaderSeparator = NSView()
        scopeHeaderSeparator.wantsLayer = true
        scopeHeaderSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        scopeHeaderSeparator.translatesAutoresizingMaskIntoConstraints = false

        scopeHeaderView.addSubview(scopeTitleLabel)
        scopeHeaderView.addSubview(scopeDisclosureImageView)
        scopeHeaderView.addSubview(scopeHeaderSeparator)
        NSLayoutConstraint.activate([
            scopeTitleLabel.leadingAnchor.constraint(equalTo: scopeHeaderView.leadingAnchor, constant: 8),
            scopeTitleLabel.centerYAnchor.constraint(equalTo: scopeHeaderView.centerYAnchor),

            scopeDisclosureImageView.leadingAnchor.constraint(
                greaterThanOrEqualTo: scopeTitleLabel.trailingAnchor, constant: 4),
            scopeDisclosureImageView.trailingAnchor.constraint(equalTo: scopeHeaderView.trailingAnchor, constant: -8),
            scopeDisclosureImageView.centerYAnchor.constraint(equalTo: scopeHeaderView.centerYAnchor),
            scopeDisclosureImageView.widthAnchor.constraint(equalToConstant: 10),
            scopeDisclosureImageView.heightAnchor.constraint(equalToConstant: 10),

            scopeHeaderView.heightAnchor.constraint(equalToConstant: 22),

            scopeHeaderSeparator.leadingAnchor.constraint(equalTo: scopeHeaderView.leadingAnchor),
            scopeHeaderSeparator.trailingAnchor.constraint(equalTo: scopeHeaderView.trailingAnchor),
            scopeHeaderSeparator.bottomAnchor.constraint(equalTo: scopeHeaderView.bottomAnchor),
            scopeHeaderSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])

        // A plain NSView, not an NSStackView -- NSStackView's cross-axis alignment can only position
        // an arranged subview at its own natural size, never stretch it to fill the stack, so
        // making scroll grow to leftColumn's full available size needs explicit constraints instead
        // of relying on stack auto-arrangement (same reasoning for detailPane below). leftColumn's
        // own size now comes from sourceSplitView (the user-draggable divider), not a fixed constant.
        let leftColumn = NSView()
        leftColumn.translatesAutoresizingMaskIntoConstraints = false
        leftColumn.addSubview(scopeHeaderView)
        leftColumn.addSubview(scroll)
        NSLayoutConstraint.activate([
            scopeHeaderView.topAnchor.constraint(equalTo: leftColumn.topAnchor),
            scopeHeaderView.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
            scopeHeaderView.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: scopeHeaderView.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: leftColumn.bottomAnchor),
        ])

        includedCheckbox.target = self
        includedCheckbox.action = #selector(includedToggled)
        geometryOnlyCheckbox.target = self
        geometryOnlyCheckbox.action = #selector(geometryOnlyToggled)
        probeImpedanceCheckbox.target = self
        probeImpedanceCheckbox.action = #selector(probeImpedanceToggled)
        simulateAsDifferentialPairCheckbox.target = self
        simulateAsDifferentialPairCheckbox.action = #selector(simulateAsDifferentialPairToggled)
        probeCheckbox.target = self
        probeCheckbox.action = #selector(probeToggled)
        absorbCheckbox.target = self
        absorbCheckbox.action = #selector(absorbToggled)

        impedanceField.formatter = impedanceFormatter
        widthField.formatter = widthFormatter
        dBMarginField.formatter = Self.numberFormatter
        for field in [impedanceField, widthField, dBMarginField] {
            field.alignment = .right
            field.target = self
            field.action = #selector(detailFieldChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
        }

        // Free text is still accepted (a typed layer number, or a name not currently in the list),
        // same as MicrometerValueFormatter's unit suffixes -- this isn't a fixed-choice popup.
        planeComboBox.target = self
        planeComboBox.action = #selector(detailFieldChanged(_:))
        planeComboBox.delegate = self
        planeComboBox.alignment = .right
        planeComboBox.widthAnchor.constraint(equalToConstant: 140).isActive = true

        directionPopUp.addItems(withTitles: DirectionKind.allCases.map(\.title))
        directionPopUp.target = self
        directionPopUp.action = #selector(directionChanged)

        customDirectionField.formatter = Self.directionFormatter
        customDirectionField.alignment = .right
        customDirectionField.target = self
        customDirectionField.action = #selector(detailFieldChanged(_:))
        customDirectionField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        // Same DirectionKind cases as directionPopUp (so the index<->case mapping stays the same
        // helper functions), but with .auto's own title swapped for this control's own meaning here
        // ("no override for this one pad", not "derive from copper").
        pinDirectionOverridePopUp.addItems(withTitles: DirectionKind.allCases.map(\.title))
        pinDirectionOverridePopUp.item(at: DirectionKind.auto.rawValue)?.title = "No Override"
        pinDirectionOverridePopUp.target = self
        pinDirectionOverridePopUp.action = #selector(pinDirectionOverrideChanged)

        pinDirectionOverrideCustomField.formatter = Self.directionFormatter
        pinDirectionOverrideCustomField.alignment = .right
        pinDirectionOverrideCustomField.target = self
        pinDirectionOverrideCustomField.action = #selector(pinDirectionOverrideCustomFieldChanged)
        pinDirectionOverrideCustomField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        excitationSeparator.wantsLayer = true
        excitationSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        excitationSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        widthDBAdvancedDisclosureButton.bezelStyle = .regularSquare
        widthDBAdvancedDisclosureButton.isBordered = false
        widthDBAdvancedDisclosureButton.imagePosition = .imageOnly
        widthDBAdvancedDisclosureButton.image = NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: "Show more override settings")
        widthDBAdvancedDisclosureButton.target = self
        widthDBAdvancedDisclosureButton.action = #selector(toggleWidthDBAdvancedRow)
        widthDBAdvancedDisclosureButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        widthDBAdvancedDisclosureButton.heightAnchor.constraint(equalToConstant: 16).isActive = true

        excitedCheckbox.target = self
        excitedCheckbox.action = #selector(excitedToggled)
        excitationTypePopUp.addItems(withTitles: ["Primary", "Adversarial"])
        excitationTypePopUp.target = self
        excitationTypePopUp.action = #selector(excitationTypeChanged)
        durationModePopUp.addItems(withTitles: ["Continuous", "Limited"])
        durationModePopUp.target = self
        durationModePopUp.action = #selector(durationModeChanged)

        startTimeField.formatter = startTimeFormatter
        durationField.formatter = durationFormatter
        phaseField.formatter = phaseFormatter
        frequencyField.formatter = frequencyFormatter
        amplitudeField.formatter = Self.numberFormatter
        for field in [startTimeField, durationField, phaseField, frequencyField, amplitudeField] {
            field.alignment = .right
            field.target = self
            field.action = #selector(excitationFieldChanged(_:))
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
        }

        let frequencyRow = labeled("Frequency:", frequencyField)
        // Shown for both main and non-main excitations -- a main excitation always uses the
        // simulation's own sweep frequency (see frequencyOnlyRows), but its amplitude is still
        // independently meaningful: e.g. giving one leg of a differential pair a second main
        // excitation at amplitude -1.0 (relative to the first leg's implicit 1.0) reconstructs the
        // pair's differential drive during postprocessing without needing a separate, narrowband
        // non-main excitation for it. See ExcitationPostprocessor::run()'s use of
        // excitation.amplitude().value_or(1.0) for main excitations.
        let amplitudeRow = labeled("Relative Amplitude:", amplitudeField)
        frequencyOnlyRows = [frequencyRow]
        durationModeRow = labeled("Duration:", durationModePopUp)
        durationRow = labeled("Duration:", durationField)

        excitationFieldsContainer = NSStackView(views: [
            labeled("Type:", excitationTypePopUp),
            labeled("Start time:", startTimeField),
            durationModeRow,
            durationRow,
            labeled("Phase:", phaseField),
            frequencyRow,
            amplitudeRow,
        ])
        excitationFieldsContainer.orientation = .vertical
        excitationFieldsContainer.alignment = .leading
        excitationFieldsContainer.spacing = 8

        includedRow = checkboxRow(includedCheckbox, title: "Simulation Net")
        geometryOnlyRow = checkboxRow(geometryOnlyCheckbox, title: "Included in Simulation")
        probeImpedanceRow = checkboxRow(probeImpedanceCheckbox, title: "Probe impedance")
        simulateAsDifferentialPairRow = checkboxRow(
            simulateAsDifferentialPairCheckbox, title: "Simulate as differential pair")
        probeRow = checkboxRow(probeCheckbox, title: "Probe")
        absorbRow = checkboxRow(absorbCheckbox, title: "Absorb Signal", labelWidth: 130)
        excitedRow = checkboxRow(excitedCheckbox, title: "Excite")
        excitationSeparatorRow = insetRow(excitationSeparator)

        impedanceRow = labeled("Connected Component Impedance:", impedanceField)
        // No stretch-to-fill spacer here (unlike SimulationPropertiesViewController's via-settings
        // row, which this otherwise mirrors) -- this row's own content (label+combo+button) is
        // already wider than impedanceRow, so forcing it to match their width via a
        // trailing constraint would conflict with its own minimum size instead of just being pointless.
        // The button sits directly after the combo box instead.
        let planeMainRow = NSStackView(views: [
            labeled("Reference Plane:", planeComboBox),
            widthDBAdvancedDisclosureButton,
        ])
        planeMainRow.orientation = .horizontal
        planeMainRow.spacing = 8

        let directionRow = NSStackView(views: [directionPopUp, customDirectionField])
        directionRow.orientation = .horizontal
        directionRow.spacing = 8
        let directionLabeledRow = labeled("Direction:", directionRow)

        let pinDirectionOverrideInnerRow = NSStackView(views: [pinDirectionOverridePopUp, pinDirectionOverrideCustomField])
        pinDirectionOverrideInnerRow.orientation = .horizontal
        pinDirectionOverrideInnerRow.spacing = 8
        pinDirectionOverrideRow = labeled("This Pad's Direction:", pinDirectionOverrideInnerRow, labelWidth: 150)

        widthDBAdvancedRow = NSStackView(views: [
            labeled("Width override:", widthField),
            labeled("dB margin override:", dBMarginField, labelWidth: 140),
        ])
        widthDBAdvancedRow.orientation = .horizontal
        widthDBAdvancedRow.spacing = 8
        widthDBAdvancedRow.isHidden = true

        // Captured so updateValueFieldsVisibility() can hide/show these together based on whether
        // includedCheckbox is actually checked -- there's nothing meaningful to show for a net/pin
        // that isn't part of the simulation yet. widthDBAdvancedRow is handled alongside these in
        // that method, but separately, since it's also gated on widthDBAdvancedRowExpanded.
        valueFieldRows = [impedanceRow, planeMainRow, directionLabeledRow]

        let leadingDetailRows: [NSView] = [
            includedRow,
            geometryOnlyRow,
            simulateAsDifferentialPairRow,
            probeImpedanceRow,
            probeRow,
            absorbRow,
        ]
        let trailingDetailRows: [NSView] = [
            widthDBAdvancedRow,
            excitationSeparatorRow,
            excitedRow,
            excitationFieldsContainer,
            detailStatusLabel,
        ]
        let detailStack = NSStackView(views: leadingDetailRows + valueFieldRows + trailingDetailRows)
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8

        // detailStack's own wrapper -- a plain NSView, not an NSStackView, for the same reason
        // leftColumn is one: detailPane is stretched to fill its split-view pane, and detailStack
        // (which doesn't need to stretch, just sit centered near the pane's top) is positioned
        // inside it with explicit constraints instead of being an NSSplitView arranged subview itself.
        let detailPane = NSView()
        detailPane.translatesAutoresizingMaskIntoConstraints = false
        detailPane.addSubview(detailStack)
        NSLayoutConstraint.activate([
            // Centered rather than pinned to the leading edge -- inequality bounds keep it from
            // clipping if the pane ever gets narrower than the fields need.
            detailStack.centerXAnchor.constraint(equalTo: detailPane.centerXAnchor),
            detailStack.leadingAnchor.constraint(greaterThanOrEqualTo: detailPane.leadingAnchor, constant: 8),
            detailStack.trailingAnchor.constraint(lessThanOrEqualTo: detailPane.trailingAnchor, constant: -8),
            // 16pt, not flush -- detailPane's top touches propertiesBackgroundSeparator (see
            // DocumentWindowController), and includedRow (detailStack's first row) would otherwise sit
            // right up against that line.
            detailStack.topAnchor.constraint(equalTo: detailPane.topAnchor, constant: 16),
        ])
        // Pinned to impedanceRow's own trailing edge, not detailStack's -- detailStack's overall width
        // is driven by whichever row is widest, which since includedRow/excitedRow's title text
        // (added by checkboxRow) isn't clipped to any fixed width, is usually one of those, not the
        // value fields. Pinning to impedanceRow instead keeps the rule aligned with the actual
        // label/field columns, matching their combined width exactly rather than whatever the
        // checkbox rows happen to need. insetRow's own internal constraints tie excitationSeparator's
        // trailing to excitationSeparatorRow's trailing, so this transitively stretches the line
        // itself to the same width. Only valid once both share a common ancestor (detailStack, just
        // established above) -- activating a constraint between two views with no common ancestor yet
        // doesn't fail cleanly, it hangs.
        excitationSeparatorRow.trailingAnchor.constraint(equalTo: impedanceRow.trailingAnchor).isActive = true

        // Gives the user a draggable divider to resize the source list against the detail pane,
        // instead of the source list's old fixed width. Holding priorities keep leftColumn's width
        // stable (and let detailPane absorb the change instead) when the window itself is resized --
        // without them, NSSplitView's default behavior here isn't documented/guaranteed.
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.delegate = self
        splitView.addArrangedSubview(leftColumn)
        splitView.addArrangedSubview(detailPane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        sourceSplitView = splitView

        view.addSubview(splitView)
        // Pinned to all four edges -- see SimulationPropertiesViewController's identical fix/comment.
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        showDetail(for: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Can't be done at buildUI time -- the split view has no real frame to position a divider
        // within until the view hierarchy is actually laid out. Only runs once; after that, the
        // divider position is whatever the user (or their last drag) left it at.
        if !didSetInitialSplitPosition, sourceSplitView.bounds.width > 0 {
            didSetInitialSplitPosition = true
            sourceSplitView.setPosition(220, ofDividerAt: 0)
        }

        // Belt-and-suspenders alongside outlineView.autoresizingMask (see buildUI): explicitly
        // reconciles both outlineView's own frame width and the text column's width with the clip
        // view's current width on every layout pass, rather than only trusting NSScrollView/
        // NSTableView's own implicit width-tracking to have already done it by the time this runs.
        // Cheap and idempotent, so doing it unconditionally here is simpler than trying to detect
        // whether the implicit mechanism already got there first.
        let visibleWidth = scroll.contentView.bounds.width
        if outlineView.frame.width != visibleWidth {
            outlineView.setFrameSize(NSSize(width: visibleWidth, height: outlineView.frame.height))
        }
        if let textColumn = outlineView.tableColumns.first {
            textColumn.width = max(0, visibleWidth - Self.iconColumnWidth)
        }
    }

    private func labeled(_ title: String, _ control: NSView, labelWidth: CGFloat = 150) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    /// A row whose content starts where labeled(...)'s *control* does, not its label -- an empty
    /// spacer of the same width stands in for the label column. Used for the rule before
    /// excitedCheckbox, so it lines up with the value fields around it instead of with the row
    /// labels ("Impedance:" etc). A plain NSView with explicit constraints, not another NSStackView
    /// row: `control` is pinned all the way to this row's own trailing edge (not just placed at its
    /// natural size), so passing a plain separator line as `control` makes it stretch to fill the row.
    private func insetRow(_ control: NSView, labelWidth: CGFloat = 150) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(spacer)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            spacer.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            spacer.topAnchor.constraint(equalTo: row.topAnchor),
            spacer.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            spacer.widthAnchor.constraint(equalToConstant: labelWidth),

            control.leadingAnchor.constraint(equalTo: spacer.trailingAnchor, constant: 8),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    /// A checkbox row where the box itself sits on the left, at the boundary between the label and
    /// field columns (its trailing edge lands at labelWidth, the same right edge every labeled(...)
    /// row's label text is right-aligned against), and its title sits to its right, starting where
    /// labeled(...)'s *control* does -- matching the request that the checkbox be on the left of the
    /// label/field gap and its title on the right, not a single combined checkbox+title control
    /// sitting entirely in the field column.
    private func checkboxRow(_ checkbox: NSButton, title: String, labelWidth: CGFloat = 150) -> NSView {
        checkbox.title = ""
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(checkbox)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            checkbox.trailingAnchor.constraint(equalTo: row.leadingAnchor, constant: labelWidth),
            checkbox.topAnchor.constraint(equalTo: row.topAnchor),
            checkbox.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 6
        return formatter
    }()

    private static let directionFormatter = PhaseValueFormatter()

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
        showDetail(for: selectedNode)
    }

    /// A reveal requested while rootNodes doesn't yet hold the right scope's data -- switchScope(to:
    /// thenReveal:) stashes it here and refreshBoardData()'s own completion applies it once the new
    /// scope's nodes have actually loaded (board parsing is asynchronous -- see refreshBoardData's own
    /// doc comment -- so this can't just happen synchronously inline).
    private enum PendingReveal {
        case net(String)
        case pin(footprintReference: String, padNumber: String)
    }
    private var pendingReveal: PendingReveal?

    /// Jumps this list to whichever net InvolvedNetsViewController's own summary table row belongs
    /// to -- switching to Net scope first if this list isn't already showing it, then expanding/
    /// selecting/scrolling to the matching leaf, the same "reveal" a user manually browsing to it
    /// would produce. Selecting it fires showDetail(for:) the normal way (via
    /// outlineViewSelectionDidChange), so the detail pane on the right fills in on its own.
    func revealNet(named netName: String) {
        switchScope(to: .net, thenReveal: .net(netName))
    }

    /// Same idea as revealNet(named:), for a specific footprint+pin -- switches to Footprint/Pin
    /// scope first if needed. `padNumber` is matched exactly against SourceListNode.Kind.pin's own
    /// pin.number -- safe because both this and InvolvedNetsViewController's own pin identities come
    /// from the same KicadBoardBridge.footprints() query (see dedupedPins' own doc comment for why a
    /// duplicate-pad-number collapse never hides a number that was genuinely present).
    func revealPin(footprintReference: String, padNumber: String) {
        switchScope(to: .footprint, thenReveal: .pin(footprintReference: footprintReference, padNumber: padNumber))
    }

    /// Shared by revealNet(named:)/revealPin(footprintReference:padNumber:) -- applies immediately if
    /// `newScope` is already showing (rootNodes already has the right data), otherwise switches scope
    /// (mirroring scopeMenuItemSelected's own reset-then-refetch sequence) and lets refreshBoardData()
    /// apply the reveal once its background fetch completes.
    private func switchScope(to newScope: Scope, thenReveal reveal: PendingReveal) {
        guard newScope != scope else {
            applyReveal(reveal)
            return
        }
        scope = newScope
        scopeTitleLabel.stringValue = Self.scopeTitles[scope.rawValue]
        rootNodes = []
        outlineView.reloadData()
        showDetail(for: nil)
        pendingReveal = reveal
        refreshBoardData()
    }

    /// Falls back to showDetail(for: nil) if the target genuinely isn't in rootNodes (e.g. a stale
    /// reveal request for a net/pin that's since been removed from the board) -- otherwise the
    /// detail pane would be left showing whatever it had before this reveal was requested, which
    /// reads as a stale, wrong-looking selection rather than "there's genuinely nothing to show."
    private func applyReveal(_ reveal: PendingReveal) {
        let found: Bool
        switch reveal {
        case .net(let name):
            found = selectNode(in: rootNodes) { node in
                if case .net(let n) = node.kind { return n == name }
                return false
            }
        case .pin(let footprintReference, let padNumber):
            found = selectNode(in: rootNodes) { node in
                if case .pin(let ref, let pin) = node.kind { return ref == footprintReference && pin.number == padNumber }
                return false
            }
        }
        if !found {
            showDetail(for: nil)
        }
    }

    /// Recursively finds `predicate`'s matching node under `nodes`, expanding every ancestor group
    /// along the way (so the target's row actually has a valid, visible index to select) and leaving
    /// it selected and scrolled into view. Collapses back any group it opened that didn't actually
    /// lead to a match, so a reveal doesn't leave unrelated branches pried open behind it. Returns
    /// whether a match was found, purely so a caller could chain further logic on failure -- nothing
    /// currently needs that, but a silent "did nothing" would be a harder failure mode to notice than
    /// an unused return value.
    @discardableResult
    private func selectNode(in nodes: [SourceListNode], matching predicate: (SourceListNode) -> Bool) -> Bool {
        for node in nodes {
            if predicate(node) {
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outlineView.scrollRowToVisible(row)
                }
                return true
            }
            guard !node.children.isEmpty else { continue }
            outlineView.expandItem(node)
            if selectNode(in: node.children, matching: predicate) {
                return true
            }
            outlineView.collapseItem(node)
        }
        return false
    }

    /// Called after a KiCad board is linked (see DocumentWindowController).
    func refreshBoardData() {
        guard let document, let board = document.board else { return }

        // In-memory already (populated by importStackup when the board was linked) -- no query
        // helper round trip needed, so this can happen synchronously, right here on the main thread.
        let currentPlaneSelection = planeComboBox.stringValue
        planeComboBox.removeAllItems()
        planeComboBox.addItems(withObjectValues: document.config.metalLayerNames)
        planeComboBox.stringValue = currentPlaneSelection

        let signposter = OSSignposter(subsystem: "com.kiems", category: "BoardLoad")
        let refreshTiming = signposter.beginInterval("Source list refresh", id: signposter.makeSignpostID())
        let currentScope = scope
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let queryTiming = signposter.beginInterval("Source list queries and nodes", id: signposter.makeSignpostID())
            let nodes: [SourceListNode]
            // Surfaced (see below) rather than swallowed by a bare `try?` -- a query failure used to
            // just look identical to "board genuinely has zero nets/footprints," with no way to tell
            // the two apart from the UI alone.
            var queryError: String?
            // Set (in whichever scope branch below actually fetches footprints) and applied on the
            // main thread alongside rootNodes/boardDataError -- allFootprints is read from the main
            // thread (differential-pair partner lookups triggered by a checkbox click), so it must
            // never be written from this background queue directly, same reasoning as nodes/
            // queryError themselves.
            var fetchedFootprints: [KicadFootprintInfo]?
            switch currentScope {
            case .netClass:
                let names: [String]
                do {
                    names = try board.netClasses()
                        .sorted(by: Self.byLocalizedStandardName)
                } catch {
                    names = []
                    queryError = error.localizedDescription
                }
                nodes = names.map { SourceListNode(kind: .netClass($0)) }
            case .net:
                var names: [String] = []
                var footprints: [KicadFootprintInfo] = []
                do {
                    names = try board.allNets()
                        .sorted(by: Self.byLocalizedStandardName)
                    footprints = try board.footprints()
                } catch {
                    queryError = error.localizedDescription
                }
                fetchedFootprints = footprints
                nodes = Self.hierarchicalNetNodes(from: names, footprints: footprints)
            case .footprint:
                var footprints: [KicadFootprintInfo] = []
                do {
                    footprints = try board.footprints()
                        .sorted { Self.byLocalizedStandardName($0.reference, $1.reference) }
                } catch {
                    queryError = error.localizedDescription
                }
                fetchedFootprints = footprints

                var footprintsByCategory: [String: [KicadFootprintInfo]] = [:]
                for footprint in footprints {
                    let category = ComponentCategory.category(forReference: footprint.reference)
                    footprintsByCategory[category, default: []].append(footprint)
                }
                // Alphabetical, except the "Other" catch-all always goes last regardless of where it
                // would otherwise fall -- it's a fallback bucket, not a real category to browse by.
                let sortedCategories = footprintsByCategory.keys.sorted { lhs, rhs in
                    if lhs == ComponentCategory.fallback { return false }
                    if rhs == ComponentCategory.fallback { return true }
                    return Self.byLocalizedStandardName(lhs, rhs)
                }

                nodes = sortedCategories.map { category in
                    let categoryNode = SourceListNode(kind: .group(category))
                    categoryNode.children = (footprintsByCategory[category] ?? []).map { footprint in
                        let node = SourceListNode(kind: .footprint(footprint))
                        // Every pin on the component -- the same net can legitimately show up more
                        // than once here, once per pin it's connected to, which is expected. What
                        // isn't wanted is the *same* logical pin appearing twice just because KiCad
                        // modeled it as more than one physical pad (see Self.dedupedPins).
                        node.children = Self.dedupedPins(footprint.pins).map {
                            SourceListNode(kind: .pin(footprintReference: footprint.reference, pin: $0))
                        }
                        return node
                    }
                    return categoryNode
                }
            }
            signposter.endInterval("Source list queries and nodes", queryTiming)
            DispatchQueue.main.async {
                defer { signposter.endInterval("Source list refresh", refreshTiming) }
                self?.rootNodes = nodes
                self?.boardDataError = queryError
                if let fetchedFootprints {
                    self?.allFootprints = fetchedFootprints
                }
                self?.outlineView.reloadData()
                if let reveal = self?.pendingReveal {
                    self?.pendingReveal = nil
                    self?.applyReveal(reveal)
                } else {
                    self?.showDetail(for: nil)
                }
            }
        }
    }

    /// "Sort by name" for net/net-class names and footprint references -- localizedStandardCompare
    /// (the same comparison Finder uses for filenames) rather than plain `<`, so embedded numbers
    /// sort numerically ("C2" before "C10") instead of lexicographically ("C10" before "C2").
    private static func byLocalizedStandardName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    /// Every pin connected to each net, as ready-made `.pin` source-list nodes (footprints' own
    /// order -- sorted below), keyed by net name -- attached as children under each net leaf by
    /// hierarchicalNetNodes, so drilling into a net shows exactly which pins are on it (the same
    /// per-pin "included"/"excited" toggles as the Footprint/Pin scope, since node.kind stays
    /// `.pin(footprintReference:pin:)`). Deduped per (net, footprint, stripped pad number/pin), the
    /// same "one row per logical pin" rule dedupedPins applies within a single footprint -- but
    /// keyed on the footprint too, unlike dedupedPins, since here pins from many different
    /// footprints are being merged into one list and a bare pad-number collision across two
    /// unrelated footprints (both having a "1", say) must not be mistaken for the same logical pin.
    private static func pinsByNet(from footprints: [KicadFootprintInfo]) -> [String: [SourceListNode]] {
        var seenPerNet: [String: Set<String>] = [:]
        var result: [String: [SourceListNode]] = [:]
        for footprint in footprints {
            for pin in footprint.pins {
                guard !pin.netName.isEmpty else { continue }
                let dedupeKey = "\(footprint.reference)\t\(SourceListNode.strippingTrailingNumericSuffix(pin.number))"
                guard seenPerNet[pin.netName, default: []].insert(dedupeKey).inserted else { continue }

                let node = SourceListNode(kind: .pin(footprintReference: footprint.reference, pin: pin))
                let function = SourceListNode.strippingTrailingNumericSuffix(pin.function)
                node.displayTitleOverride = function.isEmpty
                    ? "\(footprint.reference) pin \(pin.number)"
                    : "\(footprint.reference) pin \(pin.number) (\(function))"
                result[pin.netName, default: []].append(node)
            }
        }
        for netName in result.keys {
            result[netName]?.sort { byLocalizedStandardName($0.title, $1.title) }
        }
        return result
    }

    /// Groups net names into a tree by their "/"-separated hierarchical-sheet path components (e.g.
    /// "/MCU/DS1/En" -> group "MCU" -> group "DS1" -> leaf "En") -- a net name with no "/" at all
    /// stays a flat top-level leaf. A `{slash}` token (escaping a literal "/" that's actually *part*
    /// of a net name, not a path separator -- see NetNameFormatting) never contains a raw "/"
    /// character, so a plain split on "/" already can't mistake one for a hierarchy boundary;
    /// nothing extra is needed to tell them apart. Each leaf's `kind` keeps the full original,
    /// unsplit net name (needed for involvedNets()/KicadBoardBridge matching, which knows nothing
    /// about this grouping) -- only its *display* title is shortened to the last path component, via
    /// displayTitleOverride. Each leaf also gets every pin connected to it as a child (see
    /// pinsByNet) -- `footprints` supplies that pin/net data, a separate query from `names` itself.
    private static func hierarchicalNetNodes(from names: [String],
                                              footprints: [KicadFootprintInfo]) -> [SourceListNode] {
        let pinsByNet = Self.pinsByNet(from: footprints)

        final class GroupBuilder {
            var children: [String: GroupBuilder] = [:]
            var order: [String] = []
            var leaves: [SourceListNode] = []

            func childBuilder(for segment: String) -> GroupBuilder {
                if let existing = children[segment] { return existing }
                let builder = GroupBuilder()
                children[segment] = builder
                order.append(segment)
                return builder
            }

            /// Groups and leaves are merged into one alphabetically-sorted list, not grouped-first --
            /// matches the flat "sort by name" rule used everywhere else in this list, rather than a
            /// file-browser-style folders-before-files split nobody asked for here.
            func toNodes() -> [SourceListNode] {
                let groupNodes = order.map { segment -> SourceListNode in
                    let node = SourceListNode(kind: .group(segment))
                    node.children = children[segment]!.toNodes()
                    return node
                }
                return (groupNodes + leaves).sorted { SourceListViewController.byLocalizedStandardName($0.title, $1.title) }
            }
        }

        let root = GroupBuilder()
        for name in names {
            let segments = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !segments.isEmpty else { continue } // defensive -- name was "/" or empty
            if segments.count == 1 {
                let leaf = SourceListNode(kind: .net(name))
                leaf.children = pinsByNet[name] ?? []
                root.leaves.append(leaf)
                continue
            }
            var current = root
            for segment in segments.dropLast() {
                current = current.childBuilder(for: segment)
            }
            let leaf = SourceListNode(kind: .net(name))
            leaf.displayTitleOverride = segments.last
            leaf.children = pinsByNet[name] ?? []
            current.leaves.append(leaf)
        }
        return root.toNodes()
    }

    /// KiCad sometimes models one logical pin as multiple physical pads sharing the same pad number
    /// (e.g. a MOSFET array's footprint literally has two separate pads both numbered "1"). Collapses
    /// those down to a single row per logical pin (keeping the first pad encountered), rather than
    /// listing the same pin twice. This doesn't lose port placement on the other physical pad(s):
    /// simulation ports get placed per net (every pad on that net), not restricted to whichever
    /// specific pad an involved_nets entry names -- that name only ever identifies *which net* is
    /// meant. Routed through the same "_n" stripping as display (see
    /// SourceListNode.strippingTrailingNumericSuffix) so a board that also suffixed pad *numbers*
    /// themselves for uniqueness would still correctly dedupe by the underlying logical pin.
    private static func dedupedPins(_ pins: [KicadFootprintPin]) -> [KicadFootprintPin] {
        var seenNumbers = Set<String>()
        return pins.filter { seenNumbers.insert(SourceListNode.strippingTrailingNumericSuffix($0.number)).inserted }
    }

    private func showScopeMenu() {
        let menu = NSMenu()
        for (index, title) in Self.scopeTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(scopeMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (scope.rawValue == index) ? .on : .off
            menu.addItem(item)
        }
        // Bottom-left corner of scopeHeaderView's own (non-flipped) bounds -- menu.popUp hangs the
        // menu below-right of this point, so the menu appears attached right under the header.
        menu.popUp(positioning: nil, at: .zero, in: scopeHeaderView)
    }

    @objc private func scopeMenuItemSelected(_ sender: NSMenuItem) {
        guard let newScope = Scope(rawValue: sender.tag), newScope != scope else { return }
        scope = newScope
        scopeTitleLabel.stringValue = sender.title
        rootNodes = []
        outlineView.reloadData()
        showDetail(for: nil)
        refreshBoardData()
    }

    private func selectionChanged() {
        let row = outlineView.selectedRow
        let node = row >= 0 ? outlineView.item(atRow: row) as? SourceListNode : nil
        showDetail(for: node)
    }

    /// A node's identity, independent of any actual `SourceListNode` -- what matchingEntryIndex(for:)/
    /// entryAutoIncluding(_:in:)/matchingExcitationIndex(for:) actually key their lookups on. Needed
    /// so a differential-pair partner (a raw footprint+pin/net name derived from a heuristic net-name
    /// guess -- see offerDifferentialPairMirror) can reuse those same lookups even when it has no
    /// corresponding SourceListNode materialized in the currently-displayed scope's tree.
    private enum ToggleIdentity {
        case netClass(String)
        case net(String)
        case pin(footprintReference: String, pin: String, netName: String)
    }

    private func identity(for node: SourceListNode) -> ToggleIdentity? {
        switch node.kind {
        case .netClass(let name): return .netClass(name)
        case .net(let name): return .net(name)
        case .pin(let footprintReference, let pin):
            return .pin(footprintReference: footprintReference, pin: pin.number, netName: pin.netName)
        case .footprint, .group:
            return nil
        }
    }

    /// The involvedNets() index (if any) matching `identity`. "Included in Simulation" is a
    /// property of the *net*, not the pin -- so a `.pin` identity never matches a per-pin entry of
    /// its own; it resolves straight to the `.net`-kind entry (if any) for whatever net that pin is
    /// on (see its own `netName`). That's why selecting a pin on an already-included net shows the
    /// checkbox checked with the net's own impedance/plane (see showDetail/matchingEntry),
    /// and why editing those fields while a pin is selected edits that same shared net-level entry
    /// (see detailFieldChanged) -- there's only ever one entry per net for a pin to point at.
    /// Index-based, not object-identity-based: EMSInvolvedNetBridge wrappers are never cached (see
    /// EMSConfigBridge.mm), so two separate calls to involvedNets() never return the same instance
    /// for the same underlying entry -- `===` would never match here.
    private func matchingEntryIndex(for identity: ToggleIdentity) -> Int? {
        guard let sim = selectedSimulation else { return nil }
        switch identity {
        case .netClass(let name):
            return sim.involvedNets.firstIndex { $0.kind == .netClass && $0.netClass == name }
        case .net(let name):
            return sim.involvedNets.firstIndex { $0.kind == .net && $0.net == name }
        case .pin(_, _, let netName):
            guard !netName.isEmpty else { return nil }
            return sim.involvedNets.firstIndex { $0.kind == .net && $0.net == netName }
        }
    }

    private func matchingEntryIndex(for node: SourceListNode) -> Int? {
        identity(for: node).flatMap { matchingEntryIndex(for: $0) }
    }

    private func matchingEntry(for identity: ToggleIdentity) -> EMSInvolvedNetBridge? {
        matchingEntryIndex(for: identity).map { selectedSimulation!.involvedNets[$0] }
    }

    private func matchingEntry(for node: SourceListNode) -> EMSInvolvedNetBridge? {
        matchingEntryIndex(for: node).map { selectedSimulation!.involvedNets[$0] }
    }

    /// ExcitationConfig is inherently per footprint+pin -- only a `.pin` identity can match one.
    private func matchingExcitationIndex(for identity: ToggleIdentity) -> Int? {
        guard case .pin(let footprintReference, let pin, _) = identity, let sim = selectedSimulation
        else { return nil }
        return sim.excitations.firstIndex { $0.footprintReference == footprintReference && $0.pin == pin }
    }

    private func matchingExcitationIndex(for node: SourceListNode) -> Int? {
        identity(for: node).flatMap { matchingExcitationIndex(for: $0) }
    }

    private func matchingExcitation(for node: SourceListNode) -> EMSExcitationBridge? {
        matchingExcitationIndex(for: node).map { selectedSimulation!.excitations[$0] }
    }

    private func matchingExcitation(for identity: ToggleIdentity) -> EMSExcitationBridge? {
        matchingExcitationIndex(for: identity).map { selectedSimulation!.excitations[$0] }
    }

    /// Whether `footprint`.`pin` on `entry`'s net is effectively probed, and (only meaningful when
    /// probed) whether it absorbs the signal -- accounting for both of InvolvedNetConfig's
    /// resolution modes (see its own doc comment): while hasExplicitPinSelections is NO, every pin
    /// is probed+absorbing by default except those in the legacy excludedPins() list; once YES,
    /// only pins actually present in probedPins() are probed at all. Mirrors
    /// port_resolution.cpp's own resolution rule exactly, so what's shown here always matches what
    /// an actual simulation run would do.
    private func effectiveProbeState(for entry: EMSInvolvedNetBridge, footprintReference: String, pin: String)
        -> (probed: Bool, absorbs: Bool) {
        if entry.hasExplicitPinSelections {
            let probed = entry.isPinProbed(withFootprint: footprintReference, pin: pin)
            return (probed, probed ? entry.pinAbsorbsSignal(withFootprint: footprintReference, pin: pin) : true)
        }
        return (!entry.isPinExcluded(withFootprint: footprintReference, pin: pin), true)
    }

    /// The status icon shown to a row's left in the source list, or nil for none. Only pin/net/
    /// net-class rows (node.isSelectableForInclusion) ever get one -- a footprint or group row has
    /// no InvolvedNetConfig/ExcitationConfig identity of its own so it can be neither probed,
    /// excited, nor included. Only a `.pin` node can ever match an excitation
    /// (matchingExcitationIndex), so a net/net-class row can only ever show "included" or nothing.
    private func icon(for node: SourceListNode) -> String? {
        guard node.isSelectableForInclusion else { return nil }
        if let excitation = matchingExcitation(for: node) {
            return excitation.isMain ? "rectangle.portrait.and.arrow.right.fill" : "rectangle.portrait.and.arrow.right"
        }
        guard let entry = matchingEntry(for: node) else { return nil }
        if case .pin(let footprintReference, let pin) = node.kind {
            return effectiveProbeState(for: entry, footprintReference: footprintReference, pin: pin.number).probed
                ? "highlighter" : nil
        }
        return "highlighter"
    }

    private func showDetail(for node: SourceListNode?) {
        selectedNode = node
        guard let node else {
            setDetailFieldsHidden(true)
            if let boardDataError {
                detailStatusLabel.stringValue = "Couldn't read this board's data: \(boardDataError)"
            } else {
                detailStatusLabel.stringValue = "Select a net, net class, or pin."
            }
            return
        }
        guard node.isSelectableForInclusion else {
            setDetailFieldsHidden(true)
            detailStatusLabel.stringValue = "Select a specific pin under this footprint."
            return
        }
        guard selectedSimulation != nil else {
            setDetailFieldsHidden(true)
            detailStatusLabel.stringValue = "Select or add a simulation above."
            return
        }
        setDetailFieldsHidden(false)
        detailStatusLabel.stringValue = ""

        let isPinNode: Bool
        if case .pin = node.kind { isPinNode = true } else { isPinNode = false }
        includedRow.isHidden = isPinNode
        geometryOnlyRow.isHidden = isPinNode
        // This is visibly paired with Included in Simulation even before the net is included. It is
        // disabled until an involved-net entry exists, because that entry owns the setting.
        probeImpedanceRow.isHidden = isPinNode
        simulateAsDifferentialPairRow.isHidden = isPinNode
        probeRow.isHidden = !isPinNode
        // Visible/enabled whenever probeRow is, entry or not -- absorbToggled() auto-includes the
        // net the same way probeToggled()/excitedToggled() already do, so Absorb can be checked
        // "from nothing" exactly like Probe can.
        absorbRow.isHidden = !isPinNode

        let entry = matchingEntry(for: node)
        // GeometryOnly nets never get ports -- see kiems::NetInclusionLevel's own doc comment
        // -- so every field below that's meaningless without one (impedance/plane/direction rows are
        // hidden entirely by updateValueFieldsVisibility() for exactly this reason; probe/absorb/
        // excite are pin-level and gated right here, since they aren't covered by that method).
        let isSimulationNetEntry = entry?.inclusionLevel == .simulationNet
        if let entry {
            if !isPinNode {
                includedCheckbox.state = isSimulationNetEntry ? .on : .off
                geometryOnlyCheckbox.state = isSimulationNetEntry ? .off : .on
                probeImpedanceCheckbox.state = entry.probeImpedance ? .on : .off
                simulateAsDifferentialPairCheckbox.state = entry.simulateAsDifferentialPair ? .on : .off
                simulateAsDifferentialPairRow.isHidden = entry.differentialPairPartner == nil
            }
            impedanceField.doubleValue = entry.impedance
            planeComboBox.stringValue = planeDisplayString(for: entry.plane)
            widthField.objectValue = entry.width
            dBMarginField.objectValue = entry.dBMargin
            let kind = DirectionKind.kind(for: entry.direction?.doubleValue)
            directionPopUp.selectItem(at: kind.rawValue)
            customDirectionField.doubleValue = entry.direction?.doubleValue ?? 0
            if case .pin(let footprintReference, let pin) = node.kind {
                let state = effectiveProbeState(for: entry, footprintReference: footprintReference, pin: pin.number)
                let absorbOnly = entry.isPinAbsorbOnly(withFootprint: footprintReference, pin: pin.number)
                // Probe stays SimulationNet-only (port_resolution.cpp never reports a GeometryOnly
                // pin as a measured probe -- see NetInclusionLevel's own doc comment); Absorb is
                // independent of Probe and works for either inclusion level -- see
                // EMSInvolvedNetBridge's setPinAbsorbOnly:'s own doc comment for why a GeometryOnly
                // net's own pin still needs a real termination even though it's never probed.
                probeCheckbox.isEnabled = isSimulationNetEntry
                probeCheckbox.state = isSimulationNetEntry && state.probed ? .on : .off
                absorbCheckbox.state = (state.probed ? state.absorbs : absorbOnly) ? .on : .off
                let override = entry.directionOverride(withFootprint: footprintReference, pin: pin.number)
                let overrideKind = DirectionKind.kind(for: override?.doubleValue)
                pinDirectionOverridePopUp.selectItem(at: overrideKind.rawValue)
                pinDirectionOverrideCustomField.doubleValue = override?.doubleValue ?? 0
            }
        } else {
            if !isPinNode {
                includedCheckbox.state = .off
                geometryOnlyCheckbox.state = .off
                probeImpedanceCheckbox.state = .off
                simulateAsDifferentialPairCheckbox.state = .off
                simulateAsDifferentialPairRow.isHidden = true
            }
            probeCheckbox.isEnabled = true
            probeCheckbox.state = .off
            absorbCheckbox.state = .off
            impedanceField.stringValue = ""
            planeComboBox.stringValue = ""
            widthField.stringValue = ""
            dBMarginField.stringValue = ""
            directionPopUp.selectItem(at: DirectionKind.auto.rawValue)
            customDirectionField.stringValue = ""
            pinDirectionOverridePopUp.selectItem(at: DirectionKind.auto.rawValue)
            pinDirectionOverrideCustomField.stringValue = ""
        }
        if case .pin = node.kind {
            excitedCheckbox.isEnabled = entry == nil || isSimulationNetEntry
        }
        updateCustomDirectionFieldVisibility()
        updatePinDirectionOverrideCustomFieldVisibility()
        updateValueFieldsVisibility()

        // Excitations are per-pin only -- hidden entirely for a net/net-class selection. Unlike
        // Probe, available regardless of whether this pin has any entry/probed state yet at all
        // (checking it creates the net's entry the same way Probe does -- see excitedToggled()).
        guard case .pin = node.kind else {
            excitedRow.isHidden = true
            excitationSeparatorRow.isHidden = true
            excitationFieldsContainer.isHidden = true
            return
        }
        excitedRow.isHidden = false
        excitationSeparatorRow.isHidden = false
        if let excitation = matchingExcitation(for: node) {
            excitedCheckbox.state = .on
            excitationFieldsContainer.isHidden = false
            populateExcitationFields(from: excitation)
        } else {
            excitedCheckbox.state = .off
            excitationFieldsContainer.isHidden = true
        }
    }

    private func populateExcitationFields(from excitation: EMSExcitationBridge) {
        excitationTypePopUp.selectItem(at: excitation.isMain ? 0 : 1)
        startTimeField.doubleValue = excitation.startTime
        durationField.doubleValue = excitation.duration
        phaseField.doubleValue = excitation.phaseDegrees
        frequencyField.objectValue = excitation.frequency
        amplitudeField.objectValue = excitation.amplitude
        // frequency() is only meaningful (and only required) for a non-main excitation -- a main
        // excitation always drives at the simulation's own sweep frequency, matching
        // ExcitationConfig::frequency()'s "required iff !isMain()" contract. amplitude() stays
        // shown either way: for a non-main excitation it's required (the tone burst's own level);
        // for a main one it's optional and defaults to 1.0 (the FDTD's real per-port drive level)
        // if left blank -- only worth setting explicitly to give a second main excitation on the
        // same net (a differential pair's other leg, say) a different relative level or sign.
        for row in frequencyOnlyRows {
            row.isHidden = excitation.isMain
        }
        // A main excitation's duration is its pulse window; an adversarial one's is chosen by the
        // Duration popup, with the time field directly beneath it (unlabelled) only when Limited.
        durationModePopUp.selectItem(at: excitation.hasContinuousDuration ? 0 : 1)
        durationModeRow.isHidden = excitation.isMain
        durationRow.isHidden = !excitation.isMain && excitation.hasContinuousDuration
        (durationRow.arrangedSubviews.first as? NSTextField)?.stringValue = excitation.isMain ? "Duration:" : ""
    }

    private func setDetailFieldsHidden(_ hidden: Bool) {
        includedRow.isHidden = hidden
        geometryOnlyRow.isHidden = hidden
        simulateAsDifferentialPairRow.isHidden = hidden
        probeImpedanceRow.isHidden = hidden
        probeRow.isHidden = hidden
        absorbRow.isHidden = hidden
        if hidden {
            for row in valueFieldRows {
                row.isHidden = true
            }
            widthDBAdvancedRow.isHidden = true
            pinDirectionOverrideRow.isHidden = true
            excitedRow.isHidden = true
            excitationSeparatorRow.isHidden = true
            excitationFieldsContainer.isHidden = true
        }
        // When becoming visible (hidden == false), valueFieldRows'/widthDBAdvancedRow's/
        // pinDirectionOverrideRow's visibility is driven separately by updateValueFieldsVisibility()/
        // showDetail's own node-kind check (showDetail calls it once includedCheckbox's state is
        // known), and excitedRow/excitationSeparatorRow visibility by showDetail's own
        // pin-and-included check.
    }

    /// The value fields (Impedance/Reference Plane, plus Width override/dB margin override
    /// behind their own disclosure) are net-wide settings -- shown whenever this node's net has an
    /// entry at all, regardless of this specific pin's own Probe/Excite state (unlike the old
    /// single-checkbox model, where an individually-excluded pin also hid these, even though they
    /// describe the net, not the pin).
    private func updateValueFieldsVisibility() {
        // Requires SimulationNet specifically, not just "an entry exists at all" -- these are all
        // port/probe-oriented fields, meaningless for a GeometryOnly entry (see
        // kiems::NetInclusionLevel's own doc comment).
        let included = selectedNode.flatMap(matchingEntry)?.inclusionLevel == .simulationNet
        probeImpedanceCheckbox.isEnabled = included
        simulateAsDifferentialPairCheckbox.isEnabled = included
        for row in valueFieldRows {
            row.isHidden = !included
        }
        widthDBAdvancedRow.isHidden = !included || !widthDBAdvancedRowExpanded
        // Only meaningful for a specific pad, not a whole net/net-class -- see
        // pinDirectionOverrideRow's own declaration comment.
        let isPinNode: Bool = { if case .pin = selectedNode?.kind { return true } else { return false } }()
        // This value describes the component attached at a selected pin, not the routed net. Net
        // and net-class rows only expose the net-level probe controls and reference-plane options.
        impedanceRow.isHidden = !included || !isPinNode
        pinDirectionOverrideRow.isHidden = !included || !isPinNode
    }

    /// customDirectionField only makes sense (and is only shown) once "Custom" is picked -- every
    /// other DirectionKind either has no angle at all (.auto) or a fixed one the popup itself already
    /// names (.north/.south/.east/.west), so a free-text field next to them would just be confusing.
    private func updateCustomDirectionFieldVisibility() {
        customDirectionField.isHidden = DirectionKind(rawValue: directionPopUp.indexOfSelectedItem) != .custom
    }

    /// Same as updateCustomDirectionFieldVisibility, for pinDirectionOverrideCustomField.
    private func updatePinDirectionOverrideCustomFieldVisibility() {
        pinDirectionOverrideCustomField.isHidden =
            DirectionKind(rawValue: pinDirectionOverridePopUp.indexOfSelectedItem) != .custom
    }

    @objc private func directionChanged() {
        guard let entry = selectedNode.flatMap(matchingEntry),
              let kind = DirectionKind(rawValue: directionPopUp.indexOfSelectedItem)
        else { return }
        updateCustomDirectionFieldVisibility()
        switch kind {
        case .auto:
            entry.direction = nil
        case .north, .south, .east, .west:
            entry.direction = kind.fixedDegrees.map { NSNumber(value: $0) }
        case .custom:
            // Keeps whatever angle was already showing (a previously-set fixed direction, or 0 if
            // there wasn't one) rather than snapping straight to 0 the instant Custom is picked --
            // switching from North to Custom should start from 90, not silently reset it.
            customDirectionField.doubleValue = entry.direction?.doubleValue ?? customDirectionField.doubleValue
            entry.direction = NSNumber(value: customDirectionField.doubleValue)
        }
        document?.updateChangeCount(.changeDone)
        onInvolvedNetsChanged?()
    }

    /// Same as directionChanged(), but for this one pad's own override -- see
    /// pinDirectionOverrideRow's own declaration comment. Only reachable for a .pin node (the row
    /// is hidden otherwise), so footprintReference/pin are always available here.
    @objc private func pinDirectionOverrideChanged() {
        guard let node = selectedNode, case .pin(let footprintReference, let pin) = node.kind,
              let entry = matchingEntry(for: node),
              let kind = DirectionKind(rawValue: pinDirectionOverridePopUp.indexOfSelectedItem)
        else { return }
        updatePinDirectionOverrideCustomFieldVisibility()
        switch kind {
        case .auto:
            entry.setDirectionOverride(nil, withFootprint: footprintReference, pin: pin.number)
        case .north, .south, .east, .west:
            entry.setDirectionOverride(kind.fixedDegrees.map { NSNumber(value: $0) }, withFootprint: footprintReference,
                                        pin: pin.number)
        case .custom:
            pinDirectionOverrideCustomField.doubleValue =
                entry.directionOverride(withFootprint: footprintReference, pin: pin.number)?.doubleValue
                    ?? pinDirectionOverrideCustomField.doubleValue
            entry.setDirectionOverride(NSNumber(value: pinDirectionOverrideCustomField.doubleValue),
                                        withFootprint: footprintReference, pin: pin.number)
        }
        document?.updateChangeCount(.changeDone)
        onInvolvedNetsChanged?()
    }

    @objc private func pinDirectionOverrideCustomFieldChanged() {
        guard let node = selectedNode, case .pin(let footprintReference, let pin) = node.kind,
              let entry = matchingEntry(for: node)
        else { return }
        entry.setDirectionOverride(NSNumber(value: pinDirectionOverrideCustomField.doubleValue),
                                    withFootprint: footprintReference, pin: pin.number)
        document?.updateChangeCount(.changeDone)
        onInvolvedNetsChanged?()
    }

    @objc private func toggleWidthDBAdvancedRow() {
        widthDBAdvancedRowExpanded.toggle()
        widthDBAdvancedDisclosureButton.image = NSImage(
            systemSymbolName: widthDBAdvancedRowExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: "Show more override settings")
        updateValueFieldsVisibility()
    }

    /// The layer name at `index` among metalLayerNames, if it's in range -- falls back to just the
    /// raw number (e.g. before a board's stackup has been imported, or for a stale index past the
    /// current layer count) so there's always something sensible to show.
    private func planeDisplayString(for index: Int) -> String {
        let names = planeComboBox.objectValues.compactMap { $0 as? String }
        if index >= 0, index < names.count {
            return names[index]
        }
        return "\(index)"
    }

    /// Resolves planeComboBox's current text back to a layer index -- a name (matched against
    /// metalLayerNames, case-insensitively) if it is one, otherwise a directly-typed layer number.
    /// nil if it's neither (left for the caller to just ignore, keeping whatever was there before).
    private func resolvedPlaneIndex(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let names = planeComboBox.objectValues.compactMap { $0 as? String }
        if let index = names.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return index
        }
        return Int(trimmed)
    }

    /// Common tail every toggle handler below shares: mark the document dirty, refresh the detail
    /// pane, and reload the whole outline (not just `node`'s own branch -- toggling a net's own
    /// inclusion, or a pin's probed state on a not-yet-explicit net, can change what every *other*
    /// pin on that net resolves to (see icon(for:)/effectiveProbeState), and in Footprint/Pin scope
    /// those pins can be scattered across entirely different footprint branches). Selection doesn't
    /// survive reloadData() the way expansion state does, so it's restored explicitly right after.
    private func refreshAfterToggle(_ node: SourceListNode) {
        document?.updateChangeCount(.changeDone)
        showDetail(for: node)
        outlineView.reloadData()
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        onInvolvedNetsChanged?()
    }

    /// Only ever reached for a .net/.netClass node now -- a .pin node has no "included" checkbox of
    /// its own any more (see probeCheckbox/excitedCheckbox instead, both of which auto-include this
    /// pin's net themselves when needed). Checking this while geometryOnlyCheckbox is already on
    /// upgrades that same entry in place to .simulationNet rather than creating a second, conflicting
    /// entry for the same net -- see geometryOnlyToggled()'s own doc comment for the mirror case, and
    /// EMSNetInclusionLevel's own doc comment for why the two checkboxes share one underlying value.
    @objc private func includedToggled() {
        guard let node = selectedNode, let sim = selectedSimulation else { return }
        switch node.kind {
        case .netClass(let name):
            if includedCheckbox.state == .on {
                if let entry = matchingEntry(for: node) {
                    entry.inclusionLevel = .simulationNet
                } else {
                    let entry = sim.addInvolvedNet(with: .netClass)
                    entry.netClass = name
                }
            } else if let index = matchingEntryIndex(for: node) {
                sim.removeInvolvedNet(at: index)
            }
        case .net(let name):
            let included = includedCheckbox.state == .on
            if included {
                if let entry = matchingEntry(for: node) {
                    entry.inclusionLevel = .simulationNet
                } else {
                    let entry = sim.addInvolvedNet(with: .net)
                    entry.net = name
                }
            } else if let index = matchingEntryIndex(for: node) {
                sim.removeInvolvedNet(at: index)
            }
            refreshAfterToggle(node)
            offerDifferentialPairMirror(netIncluded: included, netName: name)
            return
        case .pin, .footprint, .group:
            break
        }
        refreshAfterToggle(node)
    }

    /// The "Included in Simulation" checkbox -- kiems::NetInclusionLevel::GeometryOnly, the
    /// narrower tier that gets an involved-nets entry's copper into the simulated geometry/mesh
    /// without hull growth or port/probe/excitation eligibility (see that enum's own doc comment).
    /// Checking this while includedCheckbox (Simulation Net) is already on downgrades that same
    /// entry in place rather than creating a second, conflicting entry for the same net -- the two
    /// checkboxes are mutually exclusive views onto one underlying inclusionLevel value, and
    /// showDetail() re-derives both states from it after every change here, so no explicit
    /// "uncheck the other one" step is needed.
    @objc private func geometryOnlyToggled() {
        guard let node = selectedNode, let sim = selectedSimulation else { return }
        switch node.kind {
        case .netClass(let name):
            if geometryOnlyCheckbox.state == .on {
                if let entry = matchingEntry(for: node) {
                    entry.inclusionLevel = .geometryOnly
                } else {
                    let entry = sim.addInvolvedNet(with: .netClass)
                    entry.netClass = name
                    entry.inclusionLevel = .geometryOnly
                }
            } else if let index = matchingEntryIndex(for: node) {
                sim.removeInvolvedNet(at: index)
            }
        case .net(let name):
            if geometryOnlyCheckbox.state == .on {
                if let entry = matchingEntry(for: node) {
                    entry.inclusionLevel = .geometryOnly
                } else {
                    let entry = sim.addInvolvedNet(with: .net)
                    entry.net = name
                    entry.inclusionLevel = .geometryOnly
                }
            } else if let index = matchingEntryIndex(for: node) {
                sim.removeInvolvedNet(at: index)
            }
        case .pin, .footprint, .group:
            break
        }
        refreshAfterToggle(node)
    }

    /// Only reached for a .net/.netClass node with an existing entry: the row remains visible next
    /// to the inclusion control, but updateValueFieldsVisibility() disables it until one exists.
    @objc private func probeImpedanceToggled() {
        guard let node = selectedNode, let entry = matchingEntry(for: node) else { return }
        entry.probeImpedance = probeImpedanceCheckbox.state == .on
        refreshAfterToggle(node)
    }

    @objc private func simulateAsDifferentialPairToggled() {
        guard let node = selectedNode, let entry = matchingEntry(for: node),
              let partnerName = entry.differentialPairPartner
        else { return }
        let enabled = simulateAsDifferentialPairCheckbox.state == .on
        entry.simulateAsDifferentialPair = enabled
        matchingEntry(for: ToggleIdentity.net(partnerName))?.simulateAsDifferentialPair = enabled
        if enabled, let netName = entry.net {
            synchronizeDifferentialExcitations(netName: netName, partnerName: partnerName)
        }
        refreshAfterToggle(node)
    }

    /// Creates `node`'s pin's net entry if it doesn't exist yet -- the auto-include behavior shared
    /// by probeToggled() and excitedToggled() (checking either one brings the net in, same as
    /// checking includedCheckbox does for a net/net-class row). Returns nil (having left the
    /// checkbox that called it unchecked) if the pin's net is somehow unknown.
    private func entryAutoIncluding(_ identity: ToggleIdentity, in sim: EMSSimulationBridge) -> EMSInvolvedNetBridge? {
        if let existing = matchingEntry(for: identity) {
            return existing
        }
        guard case .pin(_, _, let netName) = identity, !netName.isEmpty else { return nil }
        let entry = sim.addInvolvedNet(with: .net)
        entry.net = netName
        return entry
    }

    /// Records reciprocal pair membership on two concrete Net-kind entries. Newly inferred pairs
    /// default to mixed-mode simulation; the checkbox can disable that without losing identity.
    private func markDifferentialPair(_ firstName: String, _ secondName: String) {
        guard let first = matchingEntry(for: ToggleIdentity.net(firstName)),
              let second = matchingEntry(for: ToggleIdentity.net(secondName))
        else { return }
        first.differentialPairPartner = secondName
        second.differentialPairPartner = firstName
        first.simulateAsDifferentialPair = true
        second.simulateAsDifferentialPair = true
    }

    /// Makes an existing pair of source excitations an ideal odd-mode drive. Independent FDTD
    /// sweeps still use unit single-port sources; these relative settings are consumed when their
    /// responses are superposed by ExcitationPostprocessor.
    private func configureDifferentialComplement(_ partner: EMSExcitationBridge,
                                                  from source: EMSExcitationBridge) {
        partner.isMain = source.isMain
        partner.hasContinuousDuration = source.hasContinuousDuration
        partner.startTime = source.startTime
        partner.duration = source.duration
        partner.frequency = source.frequency
        partner.phaseDegrees = source.phaseDegrees
        partner.amplitude = NSNumber(value: -(source.amplitude?.doubleValue ?? 1.0))
    }

    private func synchronizeDifferentialExcitations(netName: String, partnerName: String) {
        guard let footprint = allFootprints.first(where: { footprint in
            footprint.pins.contains { $0.netName == netName } &&
                footprint.pins.contains { $0.netName == partnerName }
        }),
        let firstPin = footprint.pins.first(where: { $0.netName == netName }),
        let secondPin = footprint.pins.first(where: { $0.netName == partnerName }),
        let source = matchingExcitation(for: ToggleIdentity.pin(
            footprintReference: footprint.reference, pin: firstPin.number, netName: netName)),
        let partner = matchingExcitation(for: ToggleIdentity.pin(
            footprintReference: footprint.reference, pin: secondPin.number, netName: partnerName))
        else { return }
        configureDifferentialComplement(partner, from: source)
    }

    private func entryAutoIncluding(_ node: SourceListNode, in sim: EMSSimulationBridge) -> EMSInvolvedNetBridge? {
        guard let identity = identity(for: node) else { return nil }
        return entryAutoIncluding(identity, in: sim)
    }

    /// Absorb-only pins require the net's geometry but do not make it a simulated signal path.
    /// Unlike entryAutoIncluding(_:in:), a newly-created entry therefore starts GeometryOnly;
    /// an existing entry keeps whichever inclusion level the user already selected.
    private func entryAutoIncludingGeometryOnly(_ node: SourceListNode,
                                                 in sim: EMSSimulationBridge) -> EMSInvolvedNetBridge? {
        if let existing = matchingEntry(for: node) {
            return existing
        }
        guard case .pin(_, let pin) = node.kind, !pin.netName.isEmpty else { return nil }
        let entry = sim.addInvolvedNet(with: .net)
        entry.net = pin.netName
        entry.inclusionLevel = .geometryOnly
        entry.useExplicitPinSelections()
        return entry
    }

    // MARK: - Differential-pair mirroring

    private static let alwaysMirrorDifferentialPairChangesDefaultsKey = "AlwaysMirrorDifferentialPairChanges"

    /// A per-user (not per-document) preference -- this app's first use of UserDefaults. Deliberately
    /// not stored in simulation.json: "don't ask me about this again" is a preference about how the
    /// person wants to work, not part of the board's own configuration, so it shouldn't travel with
    /// the document or be shared with anyone else who opens it.
    private var alwaysMirrorDifferentialPairChanges: Bool {
        get { UserDefaults.standard.bool(forKey: Self.alwaysMirrorDifferentialPairChangesDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.alwaysMirrorDifferentialPairChangesDefaultsKey) }
    }

    /// The pin on `footprintReference` (if any) matching a differential-pair partner candidate for
    /// `netName`, per DifferentialPairNetHeuristic -- the first heuristic candidate that's actually
    /// a pin of this same footprint wins. Same-footprint is the only correspondence looked for here
    /// (a connector/choke/ESD-array part carrying both legs as different pins of one component) --
    /// a pair implemented as two separately-referenced components (e.g. R_DP/R_DN) isn't found by
    /// this; silently skipped rather than guessed wrong. Reads allFootprints, populated by the most
    /// recent refreshBoardData() -- empty (so this always returns nil) while browsing in .netClass
    /// scope, which never needs it.
    private func differentialPairPartnerPin(footprintReference: String, netName: String) -> KicadFootprintPin? {
        guard let footprint = allFootprints.first(where: { $0.reference == footprintReference }) else { return nil }
        for candidate in DifferentialPairNetHeuristic.partnerCandidates(for: netName) {
            if let pin = footprint.pins.first(where: { $0.netName == candidate }) {
                return pin
            }
        }
        return nil
    }

    /// Shows a confirmation sheet offering to mirror a differential-pair change, or applies it
    /// silently if the user has already opted into always doing so (see
    /// alwaysMirrorDifferentialPairChanges) -- the one shared entry point for all three mirror
    /// offers below. Follows this app's one other NSAlert precedent (JobsWindowController's
    /// requestCancel): a sheet, not a blocking runModal call, since apply() may itself need to touch
    /// UI state (outlineView.reloadData()) after the fact.
    private func confirmAndMirrorDifferentialPairChange(actionVerb: String, targetDescription: String,
                                                          apply: @escaping () -> Void) {
        if alwaysMirrorDifferentialPairChanges {
            apply()
            document?.updateChangeCount(.changeDone)
            outlineView.reloadData()
            onInvolvedNetsChanged?()
            return
        }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "\(actionVerb) \(targetDescription) too?"
        alert.informativeText = "\(targetDescription) looks like the other half of a differential pair."
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.showsSuppressionButton = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if alert.suppressionButton?.state == .on {
                self.alwaysMirrorDifferentialPairChanges = true
            }
            if response == .alertFirstButtonReturn {
                apply()
                self.document?.updateChangeCount(.changeDone)
                self.outlineView.reloadData()
                self.onInvolvedNetsChanged?()
            }
        }
    }

    /// Offers to mirror a just-applied "Included in Simulation" state onto the other half of a
    /// differential pair, guessed heuristically from `netName`'s own name (see
    /// DifferentialPairNetHeuristic). Accepting the offer persists reciprocal pair identity on the
    /// two entries. Silently does nothing if no heuristic candidate actually exists as a real net
    /// on the board, or if the partner's own state already matches.
    private func offerDifferentialPairMirror(netIncluded included: Bool, netName: String) {
        guard let sim = selectedSimulation else { return }
        guard let partnerNetName = DifferentialPairNetHeuristic.partnerCandidates(for: netName).first(where: { candidate in
            allFootprints.contains { $0.pins.contains { $0.netName == candidate } }
        }) else { return }
        let partnerIdentity = ToggleIdentity.net(partnerNetName)
        let currentlyIncluded = matchingEntry(for: partnerIdentity) != nil
        guard currentlyIncluded != included else { return }
        if !included, let remainingPartner = matchingEntry(for: partnerIdentity) {
            // The first half has already been removed. If the user keeps this half, it is now an
            // ordinary single-ended net; if they accept the mirror it is removed moments later.
            remainingPartner.differentialPairPartner = nil
            remainingPartner.simulateAsDifferentialPair = false
        }
        confirmAndMirrorDifferentialPairChange(actionVerb: included ? "Include" : "Exclude",
                                                targetDescription: "net \(partnerNetName)") { [self] in
            if included {
                let entry = sim.addInvolvedNet(with: .net)
                entry.net = partnerNetName
                markDifferentialPair(netName, partnerNetName)
            } else if let index = matchingEntryIndex(for: partnerIdentity) {
                sim.removeInvolvedNet(at: index)
            }
        }
    }

    /// Offers to mirror a just-applied Probe state onto the differential-pair partner pin (see
    /// differentialPairPartnerPin) -- always defaults Absorb Signal to on when turning Probe on,
    /// matching probeToggled()'s own single-pin default.
    private func offerDifferentialPairMirror(pinProbed probed: Bool, footprintReference: String, netName: String,
                                              padNumber: String) {
        guard let sim = selectedSimulation,
              let partner = differentialPairPartnerPin(footprintReference: footprintReference, netName: netName),
              partner.number != padNumber
        else { return }
        let partnerIdentity = ToggleIdentity.pin(footprintReference: footprintReference, pin: partner.number,
                                                  netName: partner.netName)
        let currentlyProbed = matchingEntry(for: partnerIdentity)
            .map { effectiveProbeState(for: $0, footprintReference: footprintReference, pin: partner.number).probed }
            ?? false
        guard currentlyProbed != probed else { return }
        confirmAndMirrorDifferentialPairChange(
            actionVerb: probed ? "Probe" : "Stop probing",
            targetDescription: "\(footprintReference) pin \(partner.number) (\(partner.netName))") { [self] in
            if probed {
                guard let entry = entryAutoIncluding(partnerIdentity, in: sim) else { return }
                entry.setPinProbed(true, absorbSignal: true, withFootprint: footprintReference, pin: partner.number)
                markDifferentialPair(netName, partner.netName)
                synchronizeDifferentialExcitations(netName: netName, partnerName: partner.netName)
            } else if let entry = matchingEntry(for: partnerIdentity) {
                entry.setPinProbed(false, absorbSignal: true, withFootprint: footprintReference, pin: partner.number)
            }
        }
    }

    /// Offers to mirror a just-applied Excite state onto the differential-pair partner pin (see
    /// differentialPairPartnerPin).
    private func offerDifferentialPairMirror(pinExcited excited: Bool, footprintReference: String, netName: String,
                                              padNumber: String) {
        guard let sim = selectedSimulation,
              let partner = differentialPairPartnerPin(footprintReference: footprintReference, netName: netName),
              partner.number != padNumber
        else { return }
        let partnerIdentity = ToggleIdentity.pin(footprintReference: footprintReference, pin: partner.number,
                                                  netName: partner.netName)
        let currentlyExcited = matchingExcitation(for: partnerIdentity) != nil
        guard currentlyExcited != excited else { return }
        confirmAndMirrorDifferentialPairChange(
            actionVerb: excited ? "Excite" : "Stop exciting",
            targetDescription: "\(footprintReference) pin \(partner.number) (\(partner.netName))") { [self] in
            if excited {
                guard entryAutoIncluding(partnerIdentity, in: sim) != nil else { return }
                let excitation = sim.addExcitation(forFootprint: footprintReference, pin: partner.number)
                // The companion leg is the odd-mode inverse of the excitation the user added.
                if let source = matchingExcitation(for: ToggleIdentity.pin(
                    footprintReference: footprintReference, pin: padNumber, netName: netName)) {
                    configureDifferentialComplement(excitation, from: source)
                }
                markDifferentialPair(netName, partner.netName)
            } else if let index = matchingExcitationIndex(for: partnerIdentity) {
                sim.removeExcitation(at: index)
            }
        }
    }

    // Probe x Absorb together implement a 2x2 truth table, each handler reacting to the *other*
    // checkbox's current state to decide which underlying setter applies:
    //   Probe=on,  Absorb=on  -> setPinProbed(true, absorbSignal: true)  -- measured + terminated,
    //                            today's long-standing default.
    //   Probe=on,  Absorb=off -> setPinProbed(true, absorbSignal: false) -- measured, passive
    //                            (non-loading) read point.
    //   Probe=off, Absorb=on  -> setPinAbsorbOnly(true) -- terminated, never a named/selectable
    //                            thing in Results (see EMSInvolvedNetBridge's own doc comment) --
    //                            works on a GeometryOnly net too, unlike Probe.
    //   Probe=off, Absorb=off -> no port at all for this pin.
    @objc private func probeToggled() {
        guard let node = selectedNode, case .pin(let footprintReference, let pin) = node.kind,
              let sim = selectedSimulation
        else { return }
        let probed = probeCheckbox.state == .on
        if probed {
            guard let entry = entryAutoIncluding(node, in: sim) else {
                probeCheckbox.state = .off
                return
            }
            // Defaults Absorb Signal to on -- "Probe + Absorb Signal should have the behaviour we
            // have today" is the expected default when a pin is first probed; unchecking it
            // afterwards is a separate, explicit step (absorbToggled()).
            absorbCheckbox.state = .on
            entry.setPinProbed(true, absorbSignal: true, withFootprint: footprintReference, pin: pin.number)
        } else if let entry = matchingEntry(for: node) {
            if absorbCheckbox.state == .on {
                // Absorb Signal is still checked -- fall through to absorb-only rather than losing
                // the termination this pin already had.
                entry.setPinAbsorbOnly(true, withFootprint: footprintReference, pin: pin.number)
            } else {
                entry.setPinAbsorbOnly(false, withFootprint: footprintReference, pin: pin.number)
            }
        }
        refreshAfterToggle(node)
        offerDifferentialPairMirror(pinProbed: probed, footprintReference: footprintReference, netName: pin.netName,
                                     padNumber: pin.number)
    }

    @objc private func absorbToggled() {
        guard let node = selectedNode, case .pin(let footprintReference, let pin) = node.kind,
              let sim = selectedSimulation
        else { return }
        let absorb = absorbCheckbox.state == .on
        if probeCheckbox.state == .on {
            guard let entry = matchingEntry(for: node) else { return }
            entry.setPinProbed(true, absorbSignal: absorb, withFootprint: footprintReference, pin: pin.number)
        } else if absorb {
            guard let entry = entryAutoIncludingGeometryOnly(node, in: sim) else {
                absorbCheckbox.state = .off
                return
            }
            entry.setPinAbsorbOnly(true, withFootprint: footprintReference, pin: pin.number)
        } else if let entry = matchingEntry(for: node) {
            entry.setPinAbsorbOnly(false, withFootprint: footprintReference, pin: pin.number)
        }
        refreshAfterToggle(node)
    }

    @objc private func detailFieldChanged(_ sender: NSTextField) {
        guard let entry = selectedNode.flatMap(matchingEntry) else { return }
        switch sender {
        case impedanceField: entry.impedance = sender.doubleValue
        case planeComboBox:
            if let index = resolvedPlaneIndex(from: sender.stringValue) {
                entry.plane = index
                planeComboBox.stringValue = planeDisplayString(for: index)
            }
        case widthField: entry.width = sender.stringValue.isEmpty ? nil : NSNumber(value: sender.doubleValue)
        case dBMarginField: entry.dBMargin = sender.stringValue.isEmpty ? nil : NSNumber(value: sender.doubleValue)
        case customDirectionField: entry.direction = NSNumber(value: sender.doubleValue)
        default: break
        }
        document?.updateChangeCount(.changeDone)
        // Involved-nets' table shows this same entry's impedance/reference-plane directly (see
        // InvolvedNetsViewController) -- editing them here leaves it stale until told to refresh.
        onInvolvedNetsChanged?()
    }

    @objc private func excitedToggled() {
        guard let node = selectedNode, case .pin(let footprintReference, let pin) = node.kind,
              let sim = selectedSimulation
        else { return }

        let excited = excitedCheckbox.state == .on
        if excited {
            // Available whether or not Probe has been checked -- auto-includes this pin's net
            // itself, exactly like probeToggled() does, since Excite always needs its net to be
            // part of the simulation regardless of this pin's own probed state.
            guard entryAutoIncluding(node, in: sim) != nil else {
                excitedCheckbox.state = .off
                return
            }
            _ = sim.addExcitation(forFootprint: footprintReference, pin: pin.number)
        } else if let index = matchingExcitationIndex(for: node) {
            sim.removeExcitation(at: index)
        }
        refreshAfterToggle(node)
        offerDifferentialPairMirror(pinExcited: excited, footprintReference: footprintReference, netName: pin.netName,
                                     padNumber: pin.number)
    }

    @objc private func excitationTypeChanged() {
        guard let node = selectedNode, let excitation = matchingExcitation(for: node) else { return }
        let wasMain = excitation.isMain
        excitation.isMain = excitationTypePopUp.indexOfSelectedItem == 0
        if !excitation.isMain {
            if wasMain {
                excitation.hasContinuousDuration = true
            }
            // Frequency and amplitude are required for a non-main excitation. Populate sensible
            // values when revealing those controls so a newly-created (main-by-default) source
            // remains valid even if the document is saved before either field is edited.
            if excitation.frequency == nil {
                excitation.frequency = NSNumber(value: document?.config.frequencyStart ?? 0)
            }
            if excitation.amplitude == nil {
                excitation.amplitude = NSNumber(value: 1)
            }
        }
        if case .pin(_, let pin) = node.kind,
           let partner = differentialPairPartnerPin(footprintReference: excitation.footprintReference,
                                                     netName: pin.netName),
           matchingEntry(for: node)?.simulateAsDifferentialPair == true {
            synchronizeDifferentialExcitations(netName: pin.netName, partnerName: partner.netName)
        }
        document?.updateChangeCount(.changeDone)
        populateExcitationFields(from: excitation)
        outlineView.reloadItem(node)
        onInvolvedNetsChanged?()
    }

    @objc private func durationModeChanged() {
        guard let node = selectedNode, let excitation = matchingExcitation(for: node) else { return }
        excitation.hasContinuousDuration = durationModePopUp.indexOfSelectedItem == 0
        if case .pin(_, let pin) = node.kind,
           let partner = differentialPairPartnerPin(footprintReference: excitation.footprintReference,
                                                     netName: pin.netName),
           matchingEntry(for: node)?.simulateAsDifferentialPair == true {
            synchronizeDifferentialExcitations(netName: pin.netName, partnerName: partner.netName)
        }
        document?.updateChangeCount(.changeDone)
        populateExcitationFields(from: excitation)
    }

    @objc private func excitationFieldChanged(_ sender: NSTextField) {
        guard let excitation = selectedNode.flatMap(matchingExcitation) else { return }
        switch sender {
        case startTimeField: excitation.startTime = sender.doubleValue
        case durationField: excitation.duration = sender.doubleValue
        case phaseField: excitation.phaseDegrees = sender.doubleValue
        case frequencyField: excitation.frequency = NSNumber(value: sender.doubleValue)
        case amplitudeField: excitation.amplitude = NSNumber(value: sender.doubleValue)
        default: break
        }
        if let node = selectedNode, case .pin(let footprintReference, let pin) = node.kind,
           let partner = differentialPairPartnerPin(footprintReference: footprintReference, netName: pin.netName),
           matchingEntry(for: node)?.simulateAsDifferentialPair == true {
            synchronizeDifferentialExcitations(netName: pin.netName, partnerName: partner.netName)
        }
        document?.updateChangeCount(.changeDone)
        // Involved-nets' table shows this same excitation's start time/duration/phase directly (see
        // InvolvedNetsViewController) -- editing them here leaves it stale until told to refresh.
        onInvolvedNetsChanged?()
    }
}

extension SourceListViewController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                    ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Keeps the source-list pane from being dragged down to where its own content becomes
        // unusable (scopeHeaderView's chevron/label would start overlapping, say).
        proposedMinimumPosition + 140
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                    ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Keeps the detail pane from being squeezed away entirely.
        proposedMaximumPosition - 220
    }

    /// The actual mechanism keeping leftColumn's width fixed while the window resizes (holding
    /// priority alone, set on splitView in buildUI, turned out not to be reliable here -- both
    /// panes still ended up sharing a window-resize delta rather than detailPane absorbing all of
    /// it). Returning false for leftColumn (subview 0) tells the split view not to touch its size at
    /// all when *the split view itself* is resized, leaving detailPane (subview 1, the only other
    /// arranged subview, so implicitly true) to take 100% of the delta -- this only governs
    /// frame-driven resizing, not the user dragging the divider by hand, which still works exactly
    /// as before.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview subview: NSView) -> Bool {
        subview !== splitView.arrangedSubviews.first
    }
}

extension SourceListViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? SourceListNode else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? SourceListNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SourceListNode)?.children.isEmpty == false
    }
}

extension SourceListViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SourceListNode else { return nil }

        if tableColumn?.identifier == Self.iconColumnIdentifier {
            let identifier = Self.iconColumnIdentifier
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SourceListIconCellView ?? {
                let cell = SourceListIconCellView()
                cell.identifier = identifier
                return cell
            }()
            cell.configure(icon: icon(for: node))
            return cell
        }

        let identifier = Self.mainColumnIdentifier
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NetNameCellView ?? {
            let cell = NetNameCellView()
            cell.identifier = identifier
            return cell
        }()
        cell.configure(name: node.title, font: .systemFont(ofSize: NSFont.systemFontSize))
        return cell
    }

    /// Fires for every selection change regardless of input method (mouse click or keyboard arrow
    /// keys) -- see the comment where outlineView.delegate is set for why this replaces target/action.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
    }

    /// A bare footprint or group node has nothing to toggle "included"/"excited" for -- see
    /// SourceListNode.isSelectableForInclusion's false case -- so there's nothing useful selecting
    /// one would show on the right; only leaves (pins, or hierarchical net leaves) are real,
    /// selectable rows.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SourceListNode else { return true }
        switch node.kind {
        case .footprint, .group: return false
        default: return true
        }
    }
}

extension SourceListViewController: NSComboBoxDelegate {
    /// Picking a layer from planeComboBox's dropdown list (as opposed to typing) doesn't reliably
    /// commit through target/action -- this is the one that actually fires for that case.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let entry = selectedNode.flatMap(matchingEntry) else { return }
        let index = planeComboBox.indexOfSelectedItem
        guard index >= 0 else { return }
        entry.plane = index
        document?.updateChangeCount(.changeDone)
    }
}
