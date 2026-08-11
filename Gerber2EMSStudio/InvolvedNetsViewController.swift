import Cocoa

/// One row in InvolvedNetsViewController's outline view: either a top-level included net (with its
/// impedance/reference-plane) or, nested under it, one of its pins that's excited in the simulation
/// -- see InvolvedNetsViewController's own doc comment for why a pin only ever shows up here as a
/// child of its net, never as a top-level row of its own.
private final class InvolvedNetsNode: NSObject {
    enum Kind {
        case net(name: String, impedance: Double, plane: Int)
        case excitedPin(footprintReference: String, pin: KicadFootprintPin, isMain: Bool,
                         startTime: Double, duration: Double, phaseDegrees: Double)
    }
    let kind: Kind
    var children: [InvolvedNetsNode] = []

    init(kind: Kind) {
        self.kind = kind
    }
}

/// A compact summary outline, sitting between the properties panel ("blue bar") and the net/pin
/// source list: every net actually included in whichever simulation SimulationListViewController
/// has selected, with its impedance/reference-plane, and -- nested underneath, since "included in
/// simulation" is a property of the net while "excited in simulation" is a property of the pin (see
/// SourceListViewController.matchingEntryIndex) -- any of that net's pins that are excited, each
/// with its own start time/duration/phase (impedance/reference-plane and start time/duration/phase
/// are mutually exclusive per row -- a net row shows the former blank the latter, a pin row the
/// reverse -- see viewFor tableColumn). net_class/footprint+pin InvolvedNetConfig entries resolve
/// down to individual net names, the same semantics as gerber2ems::libkicad_query::
/// resolveInvolvedNetNames on the C++ side, just recomputed here in Swift from data this app already
/// has a query for (KicadBoardBridge.footprints(), which carries each pin's net name) rather than
/// adding a new bridge round trip purely for this.
final class InvolvedNetsViewController: NSViewController {
    private weak var document: Document?
    private var selectedIndex: Int?

    private let outlineView = NSOutlineView()
    private let scroll = NSScrollView()
    private let bottomSeparator = NSView()
    // scroll/bottomSeparator's heights when there's at least one row to show -- stored so
    // updateVisibility can collapse both to 0 instead, rather than just hiding `view`: an ordinary
    // NSView's own constraints keep reserving their space even while isHidden, so hiding alone would
    // leave an empty gap between the properties panel and the source list below.
    private var scrollHeightConstraint: NSLayoutConstraint!
    private var separatorHeightConstraint: NSLayoutConstraint!
    private static let scrollHeight: CGFloat = 120

    private var netNodes: [InvolvedNetsNode] = []

    private static let netColumnIdentifier = NSUserInterfaceItemIdentifier("net")
    private static let startTimeColumnIdentifier = NSUserInterfaceItemIdentifier("startTime")
    // Impedance (a net row's own property) and duration (an excited-pin row's) share this one
    // column rather than each getting a column of their own -- the two kinds of row are mutually
    // exclusive (see viewFor tableColumn), so there's never a conflict over which value a given row
    // shows here, and a table with headerView == nil has no header text to make dual-purposing a
    // column look confusing anyway. Same reasoning pairs reference-plane with phase below.
    private static let primaryValueColumnIdentifier = NSUserInterfaceItemIdentifier("primaryValue")
    private static let secondaryValueColumnIdentifier = NSUserInterfaceItemIdentifier("secondaryValue")

    private static let impedanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 4
        return formatter
    }()

    // Same formatting rules as SourceListViewController's own startTimeField/durationField/
    // phaseField -- these are read-only display here (this table doesn't edit excitations), but the
    // displayed text should still read the same way it does in the detail pane.
    private static let startTimeFormatter = UnitSuffixValueFormatter(
        displaySuffix: "s", acceptedSuffixes: ["seconds", "second", "secs", "sec", "s"])
    private static let durationFormatter = UnitSuffixValueFormatter(
        displaySuffix: "s", acceptedSuffixes: ["seconds", "second", "secs", "sec", "s"])
    private static let phaseFormatter = PhaseValueFormatter()

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
        let netColumn = NSTableColumn(identifier: Self.netColumnIdentifier)
        netColumn.title = "Net"
        outlineView.addTableColumn(netColumn)
        outlineView.outlineTableColumn = netColumn

        // Excitation-only, blank for a net row (see viewFor tableColumn) -- there's no net-level
        // property to pair it with, unlike primaryValue/secondaryValue below.
        let startTimeColumn = NSTableColumn(identifier: Self.startTimeColumnIdentifier)
        startTimeColumn.title = "Start Time"
        startTimeColumn.width = 80
        startTimeColumn.minWidth = 80
        startTimeColumn.maxWidth = 80
        outlineView.addTableColumn(startTimeColumn)

        // Impedance (net rows) / Duration (excited-pin rows) -- see primaryValueColumnIdentifier's
        // own comment for why these share one column instead of getting one apiece.
        let primaryValueColumn = NSTableColumn(identifier: Self.primaryValueColumnIdentifier)
        primaryValueColumn.title = "Impedance / Duration"
        primaryValueColumn.width = 80
        primaryValueColumn.minWidth = 80
        primaryValueColumn.maxWidth = 80
        outlineView.addTableColumn(primaryValueColumn)

        // Reference plane (net rows) / Phase (excited-pin rows).
        let secondaryValueColumn = NSTableColumn(identifier: Self.secondaryValueColumnIdentifier)
        secondaryValueColumn.title = "Reference Plane / Phase"
        secondaryValueColumn.width = 100
        secondaryValueColumn.minWidth = 100
        secondaryValueColumn.maxWidth = 100
        outlineView.addTableColumn(secondaryValueColumn)

        outlineView.headerView = nil
        // Only netColumn (the first) grows/shrinks with the table's own width -- the rest stay their
        // fixed widths (set via min==max above) regardless.
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowSizeStyle = .small
        outlineView.delegate = self
        outlineView.dataSource = self

        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // A hard edge at this view's own bottom, the same "hairline" recipe
        // DocumentWindowController's own section separators use, so the table reads as a distinct
        // section from the source list directly below it.
        bottomSeparator.wantsLayer = true
        bottomSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        view.addSubview(bottomSeparator)
        // Fixed heights, not content-driven -- the number of involved nets can run into the
        // hundreds (e.g. a whole net class), and this table is a summary strip, not meant to push
        // the source list below it arbitrarily far down. scroll's own vertical scroller handles
        // anything past what fits. Both collapsed to 0 by updateVisibility whenever there's nothing
        // to show -- see scrollHeightConstraint's own doc comment.
        scrollHeightConstraint = scroll.heightAnchor.constraint(equalToConstant: Self.scrollHeight)
        separatorHeightConstraint = bottomSeparator.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            // Edge-to-edge, no margin -- matches SourceListViewController.view's own placement
            // directly below (see DocumentWindowController), so the two read as one continuous
            // panel rather than a narrower strip floating above a wider one.
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollHeightConstraint,

            bottomSeparator.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separatorHeightConstraint,
        ])
        updateVisibility()
    }

    /// Collapses the table down to zero height -- rather than showing an empty strip -- whenever
    /// there's nothing included in the simulation yet. Called after every `netNodes` change,
    /// including from refresh()'s async completion.
    ///
    /// Deliberately does NOT touch `view.isHidden` (it used to, but only ever as a way to also
    /// close up the gap a plain zero-height NSView still reserves -- see scrollHeightConstraint's
    /// own doc comment -- not because anything here actually needs the view invisible, which the
    /// zero-height collapse already achieves on its own). Whether this whole panel is visible at
    /// all is a decision this controller has no context for: it's owned exclusively by
    /// DocumentWindowController, which shows/hides it based on which of the outline view's 4
    /// sub-entries is currently selected. refresh()'s background work can finish (and call this)
    /// well after that selection has moved on to a different sub-entry (e.g. Geometry) -- letting
    /// it also set view.isHidden here unconditionally re-showed this panel over whatever sub-entry
    /// view was on screen by then, since it has no way to know the selection had changed underneath
    /// it.
    private func updateVisibility() {
        let hasRows = !netNodes.isEmpty
        scrollHeightConstraint.constant = hasRows ? Self.scrollHeight : 0
        separatorHeightConstraint.constant = hasRows ? 1 : 0
    }

    /// Called by DocumentWindowController (via SimulationListViewController.onSelectionChanged)
    /// whenever the selected simulation changes, including to nil.
    func setSelectedSimulationIndex(_ index: Int?) {
        selectedIndex = index
        refresh()
    }

    /// A plain-data copy of the one InvolvedNetConfig fields refresh() actually reads. Needed
    /// because EMSInvolvedNetBridge holds only a *weak* reference to its parent EMSSimulationBridge
    /// (see EMSConfigBridge.mm), and EMSSimulationBridge wrappers are never cached -- nothing keeps
    /// `document.config.simulations[selectedIndex]` (a bare temporary) alive past the expression
    /// that produced it. Holding an EMSInvolvedNetBridge itself across refresh()'s dispatch to a
    /// background queue left its parent already deallocated by the time the closure ran, so
    /// -cxxNet dereferenced a dangling pointer -- a crash, not a clean nil. Copying out plain values
    /// up front, while the bridge chain is still alive, sidesteps that entirely.
    private struct InvolvedNetSnapshot {
        let kind: EMSNetSelectorKind
        let net: String?
        let netClass: String?
        let footprintReference: String?
        let pins: [String]
        let impedance: Double
        let plane: Int
    }

    /// Same idea as InvolvedNetSnapshot, for the reasons given there -- EMSExcitationBridge holds
    /// the identical weak-parent hazard.
    private struct ExcitationSnapshot {
        let footprintReference: String
        let pin: String
        let isMain: Bool
        let startTime: Double
        let duration: Double
        let phaseDegrees: Double
    }

    /// Called whenever something that could change the resolved net list happens: the selected
    /// simulation's involvedNets()/excitations() membership (SourceListViewController.
    /// includedToggled/excitedToggled/mainExcitationToggled, via DocumentWindowController's wiring)
    /// or the linked board itself (a fresh import).
    func refresh() {
        guard let document, let selectedIndex, selectedIndex >= 0,
              selectedIndex < document.config.simulations.count,
              let kicadPcbPath = document.config.kicadPcbPath
        else {
            netNodes = []
            outlineView.reloadData()
            updateVisibility()
            return
        }
        // Read out while still on the main thread, with the real bridge chain still alive -- see
        // InvolvedNetSnapshot/ExcitationSnapshot's doc comments.
        let sim = document.config.simulations[selectedIndex]
        let entries = sim.involvedNets.map {
            InvolvedNetSnapshot(kind: $0.kind, net: $0.net, netClass: $0.netClass,
                                 footprintReference: $0.footprintReference, pins: $0.pins,
                                 impedance: $0.impedance, plane: $0.plane)
        }
        let excitations = sim.excitations.map {
            ExcitationSnapshot(footprintReference: $0.footprintReference, pin: $0.pin, isMain: $0.isMain,
                                startTime: $0.startTime, duration: $0.duration, phaseDegrees: $0.phaseDegrees)
        }
        let helperPath = AppPaths.kicadQueryHelperPath

        // Net-class resolution (and even just fetching footprints() for the pin lookup) is a real
        // subprocess round trip -- kept off the main thread, same as every other board query.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let footprints = (try? KicadBoardBridge.footprints(
                forBoard: kicadPcbPath, kicadQueryHelperPath: helperPath)) ?? []
            var netForPin: [String: String] = [:]
            var pinInfoForKey: [String: KicadFootprintPin] = [:]
            for footprint in footprints {
                for pin in footprint.pins {
                    let key = "\(footprint.reference)\t\(pin.number)"
                    pinInfoForKey[key] = pin
                    if !pin.netName.isEmpty {
                        netForPin[key] = pin.netName
                    }
                }
            }

            // First entry to resolve to a given net name wins its impedance/plane -- matches how
            // SourceListViewController.matchingEntryIndex always resolves to whichever entry it
            // finds first when more than one could apply to the same identity.
            var infoByNet: [String: (impedance: Double, plane: Int)] = [:]
            func record(_ netName: String, from entry: InvolvedNetSnapshot) {
                guard infoByNet[netName] == nil else { return }
                infoByNet[netName] = (entry.impedance, entry.plane)
            }
            for entry in entries {
                switch entry.kind {
                case .net:
                    if let net = entry.net { record(net, from: entry) }
                case .netClass:
                    if let netClass = entry.netClass,
                       let nets = try? KicadBoardBridge.netsInNetClass(
                           forBoard: kicadPcbPath, netClass: netClass, kicadQueryHelperPath: helperPath) {
                        for net in nets { record(net, from: entry) }
                    }
                case .footprintPin:
                    guard let footprintReference = entry.footprintReference else { break }
                    for pin in entry.pins {
                        if let net = netForPin["\(footprintReference)\t\(pin)"] {
                            record(net, from: entry)
                        }
                    }
                @unknown default:
                    break
                }
            }

            // Every excited pin whose net is actually included, grouped by that net -- an excited
            // pin whose net isn't included has no row here to nest under (see the class doc comment).
            var excitedPinsByNet: [String: [InvolvedNetsNode]] = [:]
            for excitation in excitations {
                let key = "\(excitation.footprintReference)\t\(excitation.pin)"
                guard let netName = netForPin[key], infoByNet[netName] != nil, let pinInfo = pinInfoForKey[key]
                else { continue }
                let node = InvolvedNetsNode(kind: .excitedPin(
                    footprintReference: excitation.footprintReference, pin: pinInfo, isMain: excitation.isMain,
                    startTime: excitation.startTime, duration: excitation.duration,
                    phaseDegrees: excitation.phaseDegrees))
                excitedPinsByNet[netName, default: []].append(node)
            }
            for netName in excitedPinsByNet.keys {
                excitedPinsByNet[netName]?.sort { $0.pinTitle.localizedStandardCompare($1.pinTitle) == .orderedAscending }
            }

            let sortedNodes = infoByNet.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { netName -> InvolvedNetsNode in
                    let info = infoByNet[netName]!
                    let node = InvolvedNetsNode(kind: .net(name: netName, impedance: info.impedance, plane: info.plane))
                    node.children = excitedPinsByNet[netName] ?? []
                    return node
                }
            DispatchQueue.main.async {
                self?.netNodes = sortedNodes
                self?.outlineView.reloadData()
                // Excited pins are the whole point of nesting them here -- shown open by default
                // rather than making the user click through every net to discover them.
                self?.outlineView.expandItem(nil, expandChildren: true)
                self?.updateVisibility()
            }
        }
    }

    /// The layer name at `index` among the board's metal layers, if it's in range -- falls back to
    /// just the raw number (e.g. a stale index past the current layer count) so there's always
    /// something sensible to show. Same fallback rule as SourceListViewController's own
    /// planeDisplayString, just reading metalLayerNames directly instead of via a live combo box.
    private func planeDisplayString(for index: Int) -> String {
        let names = document?.config.metalLayerNames ?? []
        if index >= 0, index < names.count {
            return names[index]
        }
        return "\(index)"
    }
}

private extension InvolvedNetsNode {
    /// Display text for the "Net" column -- a net's own name, or an excited pin's
    /// footprint+number(+function), matching SourceListViewController's own "ref pin number
    /// (function)" format for a pin nested under a net.
    var pinTitle: String {
        switch kind {
        case .net(let name, _, _):
            return name
        case .excitedPin(let footprintReference, let pin, let isMain, _, _, _):
            let function = SourceListNode.strippingTrailingNumericSuffix(pin.function)
            let base = function.isEmpty
                ? "\(footprintReference) pin \(pin.number)"
                : "\(footprintReference) pin \(pin.number) (\(function))"
            return isMain ? "\(base) (Main Excitation)" : base
        }
    }
}

extension InvolvedNetsViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? InvolvedNetsNode else { return netNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? InvolvedNetsNode else { return netNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? InvolvedNetsNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? InvolvedNetsNode else { return nil }

        switch tableColumn?.identifier {
        case Self.startTimeColumnIdentifier:
            let text: String
            if case .excitedPin(_, _, _, let startTime, _, _) = node.kind {
                text = Self.startTimeFormatter.string(for: NSNumber(value: startTime)) ?? ""
            } else {
                text = ""
            }
            return textCell(outlineView, identifier: Self.startTimeColumnIdentifier, text: text, alignment: .right)
        case Self.primaryValueColumnIdentifier:
            let text: String
            switch node.kind {
            case .net(_, let impedance, _):
                text = "\(Self.impedanceFormatter.string(from: NSNumber(value: impedance)) ?? "\(impedance)") Ω"
            case .excitedPin(_, _, _, _, let duration, _):
                text = Self.durationFormatter.string(for: NSNumber(value: duration)) ?? ""
            }
            return textCell(outlineView, identifier: Self.primaryValueColumnIdentifier, text: text, alignment: .right)
        case Self.secondaryValueColumnIdentifier:
            let text: String
            switch node.kind {
            case .net(_, _, let plane):
                text = planeDisplayString(for: plane)
            case .excitedPin(_, _, _, _, _, let phaseDegrees):
                text = Self.phaseFormatter.string(for: NSNumber(value: phaseDegrees)) ?? ""
            }
            return textCell(outlineView, identifier: Self.secondaryValueColumnIdentifier, text: text, alignment: .right)
        default:
            let identifier = Self.netColumnIdentifier
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NetNameCellView ?? {
                let cell = NetNameCellView()
                cell.identifier = identifier
                return cell
            }()
            cell.configure(name: node.pinTitle, font: .systemFont(ofSize: NSFont.smallSystemFontSize))
            return cell
        }
    }

    /// A plain NSTextField-backed cell for every column but the net one -- none of them need
    /// NetNameCellView's overline-drawing machinery, just a label.
    private func textCell(_ outlineView: NSOutlineView, identifier: NSUserInterfaceItemIdentifier, text: String,
                           alignment: NSTextAlignment) -> NSView {
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let label = cell.textField {
            label.stringValue = text
            return cell
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = alignment
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
