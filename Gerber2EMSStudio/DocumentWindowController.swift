import Cocoa
import UniformTypeIdentifiers

/// Owns the KiCad project/board picker at the top of the window (this phase's scope) and hosts a
/// placeholder for Phases 6-8's editor content below it.
final class DocumentWindowController: NSWindowController {
    // Set explicitly at init, not read back via the inherited `document` property: that property
    // is only guaranteed to be set by NSDocument.addWindowController(_:) *after* this object has
    // already been fully constructed, and windowDidLoad() has no documented ordering guarantee
    // relative to it either -- building the UI against `currentDocument` there silently produced a
    // completely empty window whenever windowDidLoad() ran first (a `guard let doc = ... else {
    // return }` bailed out of buildUI() before anything was ever added to contentView). Taking the
    // document as a constructor parameter instead removes the race entirely.
    private let ownerDocument: Document

    private let projectPathField = NSPathControl()
    private let projectSelectionButton = NSButton()
    private let boardPopUp = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private var simulationListViewController: SimulationListViewController?
    private var propertiesViewController: SimulationPropertiesViewController?
    private var involvedNetsViewController: InvolvedNetsViewController?
    private var sourceListViewController: SourceListViewController?
    private var geometryViewController: GeometryViewController?
    private var simulationResultsViewController: SimulationResultsViewController?
    private var fieldViewerViewController: FieldViewerViewController?
    private var noSelectionLabel: NSTextField?
    private var propertiesBackgroundStrip: NSView?
    /// Kept in sync by simulationListVC.onSelectionChanged -- sourceListVC.onInvolvedNetsChanged
    /// needs to know which simulation to invalidate the geometry cache for, but doesn't carry that
    /// index itself (it fires for whichever simulation SourceListViewController is currently
    /// editing, which is always this one).
    private var currentSimulationIndex: Int?

    private var boardCandidates: [URL] = []

    init(document: Document) {
        ownerDocument = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Gerber2EMS Simulation"
        window.center()
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let projectPathLabel = NSTextField(labelWithString: "Project: ")
        projectPathLabel.setContentHuggingPriority(.required, for: .horizontal)
        projectPathLabel.alignment = .right
        projectPathLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        
        projectPathField.placeholderString = "None Selected"
        projectPathField.focusRingType = .none
        // Unlike its siblings (projectPathLabel's NSTextField, projectSelectionButton's explicit
        // 16pt), NSPathControl doesn't reliably report a usable intrinsic height on its own --
        // exactly the same class of missing-constraint bug as boardPopUp above, just surfacing on
        // a different view once that one was fixed.
        projectPathField.heightAnchor.constraint(equalToConstant: 16).isActive = true
        
        projectSelectionButton.isEnabled = true
        projectSelectionButton.isBordered = false
        projectSelectionButton.imageScaling = .scaleProportionallyDown
        projectSelectionButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        projectSelectionButton.heightAnchor.constraint(equalToConstant: 16).isActive = true
        projectSelectionButton.imagePosition = .imageOnly
        projectSelectionButton.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Choose a project")
        projectSelectionButton.target = self
        projectSelectionButton.action = #selector(chooseProject)
        
        let projectPathStack = NSStackView(views: [projectPathLabel, projectPathField, projectSelectionButton])
        projectPathStack.orientation = .horizontal
        projectPathStack.alignment = .centerY
        projectPathStack.spacing = 8
        projectPathStack.setContentHuggingPriority(.required, for: .vertical)
        
        let projectPathLabelConstraint = projectPathLabel.topAnchor.constraint(equalTo: projectPathStack.topAnchor)
        let projectPathFieldConstraint = projectPathField.topAnchor.constraint(equalTo: projectPathStack.topAnchor)
        let projectSelectionButtonConstraint = projectSelectionButton.topAnchor.constraint(equalTo: projectPathStack.topAnchor)
        projectPathLabelConstraint.priority = NSLayoutConstraint.Priority(rawValue: 800)
        projectPathFieldConstraint.priority = NSLayoutConstraint.Priority(rawValue: 800)
        projectSelectionButtonConstraint.priority = NSLayoutConstraint.Priority(rawValue: 800)
        NSLayoutConstraint.activate([
            projectPathLabel.leadingAnchor.constraint(equalTo: projectPathStack.leadingAnchor),
            projectSelectionButton.trailingAnchor.constraint(equalTo: projectPathStack.trailingAnchor),
            
            projectPathLabelConstraint,
            projectPathFieldConstraint,
            projectSelectionButtonConstraint
        ])
        
        boardPopUp.target = self
        boardPopUp.action = #selector(boardSelected)
        boardPopUp.isEnabled = false
        boardPopUp.addItem(withTitle: "Select a board…")
        
        progressIndicator.style = .spinning
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.controlSize = .small
        
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        
        let boardSelectionView = NSStackView(views: [statusLabel, boardPopUp, progressIndicator])
        boardSelectionView.orientation = .horizontal
        boardSelectionView.alignment = .centerY
        boardSelectionView.spacing = 8
        boardSelectionView.setContentHuggingPriority(.required, for: .vertical)
        boardPopUp.isHidden = true
        // NSStackView deactivates a hidden arranged subview's own automatic alignment constraint --
        // that left boardPopUp with no real vertical constraint at all whenever it's hidden (its
        // initial state), which was the actual underconstrained view letting this whole header
        // balloon: the missing pin gave Auto Layout a genuine spare degree of freedom, and it opened
        // up boardSelectionView (then topStack, then topSectionView) to fill it. Pinning boardPopUp's
        // centerY explicitly, independent of the stack's own hidden-view handling, closes that gap
        // regardless of whether it's currently shown or hidden.
        boardPopUp.centerYAnchor.constraint(equalTo: boardSelectionView.centerYAnchor).isActive = true
        
        let statusLabelConstraint = statusLabel.topAnchor.constraint(equalTo: boardSelectionView.topAnchor)
        let boardPopUpConstraint = boardPopUp.topAnchor.constraint(equalTo: boardSelectionView.topAnchor)
        let progressIndicatorConstraint = progressIndicator.topAnchor.constraint(equalTo: boardSelectionView.topAnchor)
        statusLabelConstraint.priority = NSLayoutConstraint.Priority(rawValue: 800)
        boardPopUpConstraint.priority = NSLayoutConstraint.Priority(rawValue: 800)
        progressIndicatorConstraint.priority = NSLayoutConstraint.Priority(rawValue: 800)

        let topStack = NSStackView(views: [projectPathStack, boardSelectionView])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 4
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            projectPathStack.leadingAnchor.constraint(equalTo: topStack.leadingAnchor),
            projectPathStack.trailingAnchor.constraint(equalTo: topStack.trailingAnchor),
            projectPathStack.topAnchor.constraint(equalTo: topStack.topAnchor),
            // projectPathStack's bottom was never explicitly pinned to anything -- it relied entirely
            // on topStack's own automatic inter-subview spacing to position boardSelectionView below
            // it, same underconstrained-gap pattern as topStack/topSectionSeparator above, just one
            // level further in. Pinning it directly closes that gap explicitly instead of trusting
            // the stack's own arrangement to hold it (spacing constant matches topStack.spacing).
            boardSelectionView.topAnchor.constraint(equalTo: projectPathStack.bottomAnchor, constant: 4),
            boardSelectionView.leadingAnchor.constraint(equalTo: topStack.leadingAnchor, constant: 96),
            boardSelectionView.trailingAnchor.constraint(equalTo: topStack.trailingAnchor),
            boardSelectionView.bottomAnchor.constraint(equalTo: topStack.bottomAnchor),
            
            statusLabelConstraint,
            boardPopUpConstraint,
            progressIndicatorConstraint
        ])

        // The project/board picker bar -- just a touch darker than the rest of the window (not a
        // forced dark-mode panel, which read as far too heavy) with a hard, 1pt edge at its bottom
        // rather than a soft fade, so it's unambiguous where it ends.
        let topSectionView = NSVisualEffectView()
        topSectionView.material = .headerView
        topSectionView.blendingMode = .withinWindow
        topSectionView.state = .active
        topSectionView.translatesAutoresizingMaskIntoConstraints = false

        // A light tint over the header material -- headerView material alone barely differs from
        // the window background, so this is what actually makes the bar read as separate.
        let topSectionTint = NSView()
        topSectionTint.wantsLayer = true
        topSectionTint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
        topSectionTint.translatesAutoresizingMaskIntoConstraints = false

        let topSectionSeparator = NSView()
        topSectionSeparator.wantsLayer = true
        topSectionSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        topSectionSeparator.translatesAutoresizingMaskIntoConstraints = false

        // Tint added before topStack so it sits behind the controls, not over them.
        topSectionView.addSubview(topSectionTint)
        topSectionView.addSubview(topStack)
        topSectionView.addSubview(topSectionSeparator)
        topSectionView.setContentHuggingPriority(.required, for: .vertical)
        
        // topStack's bottom used to be pinned to topSectionView.bottomAnchor directly -- the same
        // anchor simulationListVC.view.top and rightColumn.top also hang off of, below. That made
        // topSectionView.bottomAnchor a shared hub with several unrelated downstream readers, and
        // topStack's own height (a low-priority hug preference, not a hard value) was the only thing
        // ever pinning it -- nothing independent. Pinning topStack's bottom straight to the
        // separator's top instead makes topStack -> separator -> topSectionView.bottom a single,
        // private, exclusive chain: topSectionView's height stays fully dynamic (no baked-in
        // constant, so it still grows correctly with larger accessibility text sizes), and nothing
        // else sharing that hub anchor can pull on the chain that actually determines it.
        NSLayoutConstraint.activate([
            topSectionTint.leadingAnchor.constraint(equalTo: topSectionView.leadingAnchor),
            topSectionTint.trailingAnchor.constraint(equalTo: topSectionView.trailingAnchor),
            topSectionTint.topAnchor.constraint(equalTo: topSectionView.topAnchor),
            topSectionTint.bottomAnchor.constraint(equalTo: topSectionView.bottomAnchor),

            topStack.topAnchor.constraint(equalTo: topSectionView.topAnchor, constant: 16),
            topStack.leadingAnchor.constraint(equalTo: topSectionView.leadingAnchor, constant: 16),
            topStack.trailingAnchor.constraint(equalTo: topSectionView.trailingAnchor, constant: -16),
            topStack.bottomAnchor.constraint(equalTo: topSectionSeparator.topAnchor, constant: -16),

            topSectionSeparator.leadingAnchor.constraint(equalTo: topSectionView.leadingAnchor),
            topSectionSeparator.trailingAnchor.constraint(equalTo: topSectionView.trailingAnchor),
            topSectionSeparator.bottomAnchor.constraint(equalTo: topSectionView.bottomAnchor),
            topSectionSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])

        let propertiesVC = SimulationPropertiesViewController(document: ownerDocument)
        propertiesViewController = propertiesVC

        let involvedNetsVC = InvolvedNetsViewController(document: ownerDocument)
        involvedNetsViewController = involvedNetsVC

        // Each simulation's 3 outline sub-entries (Geometry/Simulation Results/Field Viewer) present
        // one of these instead of the properties/involved-nets/source-list trio -- see
        // simulationListVC.onSelectionChanged below.
        let geometryVC = GeometryViewController(document: ownerDocument)
        geometryViewController = geometryVC

        let sourceListVC = SourceListViewController(document: ownerDocument)
        sourceListViewController = sourceListVC
        // See includedToggled's own doc comment -- involvedNetsVC's table has no way to know on its
        // own that a net/net-class/pin's "Included in Simulation" state just changed. A net's
        // membership/impedance/plane/width also change what the geometry step actually builds
        // (port placement, hull extent), so a stale cached geometry/error from before the edit
        // can't keep being shown either -- see GeometryViewController.invalidateCache's own doc
        // comment. (This also fires for excitation-only edits, e.g. start time/phase, which don't
        // actually change the geometry -- an unnecessary cache clear there, not an incorrect one:
        // worst case is one avoidable re-run next time Geometry is opened.)
        sourceListVC.onInvolvedNetsChanged = { [weak involvedNetsVC, weak geometryVC, weak self] in
            involvedNetsVC?.refresh()
            if let index = self?.currentSimulationIndex {
                geometryVC?.invalidateCache(forSimulationIndex: index)
            }
        }
        let simulationResultsVC = SimulationResultsViewController()
        simulationResultsViewController = simulationResultsVC
        let fieldViewerVC = FieldViewerViewController()
        fieldViewerViewController = fieldViewerVC

        // Force these views to load (running their buildUI()) before simulationListVC's view is
        // touched below -- simulationListVC's loadView() fires its initial selection callback
        // synchronously, which reaches into propertiesVC/sourceListVC's UI. If their own loadView()
        // hadn't run yet, that callback would hit not-yet-built controls (e.g. SourceListViewController's
        // `excitationFieldsContainer: NSStackView!`, still nil) and crash.
        _ = propertiesVC.view
        _ = involvedNetsVC.view
        _ = sourceListVC.view
        _ = geometryVC.view
        _ = simulationResultsVC.view
        _ = fieldViewerVC.view
        propertiesVC.view.translatesAutoresizingMaskIntoConstraints = false
        involvedNetsVC.view.translatesAutoresizingMaskIntoConstraints = false
        sourceListVC.view.translatesAutoresizingMaskIntoConstraints = false
        geometryVC.view.translatesAutoresizingMaskIntoConstraints = false
        simulationResultsVC.view.translatesAutoresizingMaskIntoConstraints = false
        fieldViewerVC.view.translatesAutoresizingMaskIntoConstraints = false
        geometryVC.view.isHidden = true
        simulationResultsVC.view.isHidden = true
        fieldViewerVC.view.isHidden = true

        // Shown instead of propertiesVC.view (hidden entirely, not just its fields disabled)
        // whenever nothing is selected -- see simulationListVC.onSelectionChanged below.
        let noSelectionLabel = NSTextField(labelWithString: "No Simulation Selected")
        noSelectionLabel.font = .systemFont(ofSize: 28, weight: .medium)
        noSelectionLabel.textColor = .tertiaryLabelColor
        noSelectionLabel.alignment = .center
        noSelectionLabel.translatesAutoresizingMaskIntoConstraints = false
        self.noSelectionLabel = noSelectionLabel

        // Spans the full window width (including behind the sidebar -- added to contentView before
        // it, below, so the sidebar's glass draws on top) and sits flush against topSectionView's
        // bottom edge with no gap. Its own bottom tracks propertiesVC.view's bottom directly, so it
        // still fits exactly when the via-settings disclosure row expands/collapses.
        let propertiesBackgroundStrip = NSView()
        propertiesBackgroundStrip.wantsLayer = true
        propertiesBackgroundStrip.layer?.backgroundColor =
            NSColor(red: 0.55, green: 0.62, blue: 0.72, alpha: 0.16).cgColor
        propertiesBackgroundStrip.translatesAutoresizingMaskIntoConstraints = false
        self.propertiesBackgroundStrip = propertiesBackgroundStrip

        // A hard edge at the strip's own bottom, same "hairline" recipe as topSectionSeparator --
        // sourceListVC.view (below) touches this line directly, so it reads as a clean boundary
        // rather than the blue simply fading into whatever's beneath it.
        let propertiesBackgroundSeparator = NSView()
        propertiesBackgroundSeparator.wantsLayer = true
        propertiesBackgroundSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        propertiesBackgroundSeparator.translatesAutoresizingMaskIntoConstraints = false
        propertiesBackgroundStrip.addSubview(propertiesBackgroundSeparator)
        NSLayoutConstraint.activate([
            propertiesBackgroundSeparator.leadingAnchor.constraint(equalTo: propertiesBackgroundStrip.leadingAnchor),
            propertiesBackgroundSeparator.trailingAnchor.constraint(
                equalTo: propertiesBackgroundStrip.trailingAnchor),
            propertiesBackgroundSeparator.bottomAnchor.constraint(equalTo: propertiesBackgroundStrip.bottomAnchor),
            propertiesBackgroundSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])

        let simulationListVC = SimulationListViewController(document: ownerDocument)
        simulationListViewController = simulationListVC
        // Reopening a document that already has a board linked -- add/remove should already be
        // usable, not just after a fresh link this session.
        simulationListVC.setProjectAvailable(ownerDocument.config.kicadPcbPath != nil)
        // ...and the picker header/net lists need to reflect that too -- restoreLinkedBoardIfNeeded
        // is everything importSucceeded does *except* the two actions that only make sense the
        // moment a board is first linked (adding a new simulation, re-running linkKicadPCB itself).
        restoreLinkedBoardIfNeeded()
        // Renaming a simulation has no other way to reach the sidebar row showing its (now stale) name.
        propertiesVC.onNameChanged = { [weak simulationListVC] in simulationListVC?.refreshRows() }
        // ...and the reverse: a rename made directly in the sidebar (see SimulationNameField) has no
        // other way to reach propertiesVC's own name field if it's showing that same simulation.
        simulationListVC.onSimulationRenamed = { [weak propertiesVC] index in
            propertiesVC?.refreshNameFieldIfSelected(index: index)
        }
        // See SimulationPropertiesViewController.onGeometryParametersChanged's own doc comment --
        // a hull-padding/via/ground-net edit invalidates whichever simulation it belongs to.
        propertiesVC.onGeometryParametersChanged = { [weak geometryVC] index in
            geometryVC?.invalidateCache(forSimulationIndex: index)
        }
        // See GeometryViewController.onRunStateChanged's doc comment -- the spinner next to a
        // simulation's "Geometry" row has no other way to know a background pipeline run started/
        // finished for it.
        geometryVC.onRunStateChanged = { [weak simulationListVC] index, isRunning in
            simulationListVC?.setGeometryRowBusy(isRunning, forSimulationIndex: index)
        }
        simulationListVC.onSelectionChanged = { [weak self] selection in
            guard let self else { return }

            // Exactly one of these 4 is shown at a time -- selecting a simulation itself shows the
            // properties/involved-nets/source-list trio (as before Phase 5's outline-view rework);
            // selecting one of its 3 sub-entries shows that entry's own view controller instead,
            // filling the same region. setSelectedSimulationIndex is only called on the trio for the
            // .simulation case (not unconditionally for every case, as this used to do) --
            // InvolvedNetsViewController.refresh() re-shows its own view asynchronously once it has
            // rows, regardless of which of the 4 is actually on screen; calling it while a sub-entry
            // (e.g. Geometry) is showing let it pop back up over that sub-entry's view once its
            // background refresh finished.
            var showsSimulationDetail = false
            var showsGeometry = false
            var showsSimulationResults = false
            var showsFieldViewer = false
            switch selection {
            case .simulation(let index):
                showsSimulationDetail = true
                self.currentSimulationIndex = index
                self.propertiesViewController?.setSelectedSimulationIndex(index)
                self.involvedNetsViewController?.setSelectedSimulationIndex(index)
                self.sourceListViewController?.setSelectedSimulationIndex(index)
            case .geometry(let index):
                showsGeometry = true
                self.geometryViewController?.showGeometry(forSimulationIndex: index)
            case .simulationResults: showsSimulationResults = true
            case .fieldViewer: showsFieldViewer = true
            case nil:
                self.currentSimulationIndex = nil
                self.propertiesViewController?.setSelectedSimulationIndex(nil)
                self.involvedNetsViewController?.setSelectedSimulationIndex(nil)
                self.sourceListViewController?.setSelectedSimulationIndex(nil)
            }

            self.propertiesViewController?.view.isHidden = !showsSimulationDetail
            self.involvedNetsViewController?.view.isHidden = !showsSimulationDetail
            self.sourceListViewController?.view.isHidden = !showsSimulationDetail
            self.propertiesBackgroundStrip?.isHidden = !showsSimulationDetail
            self.geometryViewController?.view.isHidden = !showsGeometry
            self.simulationResultsViewController?.view.isHidden = !showsSimulationResults
            self.fieldViewerViewController?.view.isHidden = !showsFieldViewer
            self.noSelectionLabel?.isHidden = selection != nil
        }
        simulationListVC.view.translatesAutoresizingMaskIntoConstraints = false

        // An invisible container spanning the whole area right of the sidebar, purely so
        // noSelectionLabel can be centered in that region rather than in the whole window (which
        // would put it off-center, since the sidebar eats the left 220pt).
        let rightRegion = NSView()
        rightRegion.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(propertiesBackgroundStrip)
        contentView.addSubview(topSectionView)
        contentView.addSubview(simulationListVC.view)
        contentView.addSubview(rightRegion)
        rightRegion.addSubview(propertiesVC.view)
        rightRegion.addSubview(involvedNetsVC.view)
        rightRegion.addSubview(sourceListVC.view)
        rightRegion.addSubview(geometryVC.view)
        rightRegion.addSubview(simulationResultsVC.view)
        rightRegion.addSubview(fieldViewerVC.view)
        rightRegion.addSubview(noSelectionLabel)

        NSLayoutConstraint.activate([
            topSectionView.topAnchor.constraint(equalTo: contentView.topAnchor),
            topSectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topSectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            simulationListVC.view.widthAnchor.constraint(equalToConstant: 220),
            simulationListVC.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            // Overlaps upward into topSectionView by topOverlap -- the glass panel visually runs
            // under the header's hard edge; SimulationListViewController insets its own content by
            // a matching-plus-margin amount so the first row still reads clearly below the cutoff.
            simulationListVC.view.topAnchor.constraint(
                equalTo: topSectionView.bottomAnchor, constant: -SimulationListViewController.topOverlap),
            simulationListVC.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),

            rightRegion.topAnchor.constraint(equalTo: topSectionView.bottomAnchor),
            rightRegion.leadingAnchor.constraint(equalTo: simulationListVC.view.trailingAnchor),
            rightRegion.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rightRegion.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            propertiesVC.view.topAnchor.constraint(equalTo: rightRegion.topAnchor),
            propertiesVC.view.leadingAnchor.constraint(equalTo: rightRegion.leadingAnchor, constant: 16),
            propertiesVC.view.trailingAnchor.constraint(lessThanOrEqualTo: rightRegion.trailingAnchor, constant: -16),

            noSelectionLabel.centerXAnchor.constraint(equalTo: rightRegion.centerXAnchor),
            noSelectionLabel.centerYAnchor.constraint(equalTo: rightRegion.centerYAnchor),

            // These reference propertiesVC.view, a descendant of rightRegion added above -- valid now
            // that both share contentView as a common ancestor (activating a constraint between views
            // with no common ancestor yet doesn't fail cleanly, it hangs).
            propertiesBackgroundStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            propertiesBackgroundStrip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            propertiesBackgroundStrip.topAnchor.constraint(equalTo: topSectionView.bottomAnchor),
            propertiesBackgroundStrip.bottomAnchor.constraint(equalTo: propertiesVC.view.bottomAnchor),

            // involvedNetsVC.view: same full-width, no-margin placement as sourceListVC.view below it
            // (see that constraint block's own comment) -- touches the blue bar's bottom directly.
            involvedNetsVC.view.topAnchor.constraint(equalTo: propertiesBackgroundStrip.bottomAnchor),
            involvedNetsVC.view.leadingAnchor.constraint(equalTo: rightRegion.leadingAnchor),
            involvedNetsVC.view.trailingAnchor.constraint(equalTo: rightRegion.trailingAnchor),

            // sourceListVC.view: touches involvedNetsVC.view's bottom, touches the sidebar's right
            // edge (no margin, unlike propertiesVC.view's 16pt inset above), and extends to the
            // window's bottom -- independent of propertiesVC.view now, not stacked below it with
            // spacing. Trailing is an equality, not propertiesVC.view's lessThanOrEqualTo --
            // sourceListVC.view now hosts an NSSplitView internally (see SourceListViewController),
            // which has no intrinsic content width of its own to fall back on (its arranged
            // subviews' sizes are meant to be imposed top-down by the divider, not derived
            // bottom-up from content the way a plain NSStackView's is). Without a real width pinned
            // all the way down, the whole chain -- lacking any other width-determining constraint --
            // collapsed to zero.
            sourceListVC.view.topAnchor.constraint(equalTo: involvedNetsVC.view.bottomAnchor),
            sourceListVC.view.leadingAnchor.constraint(equalTo: rightRegion.leadingAnchor),
            sourceListVC.view.trailingAnchor.constraint(equalTo: rightRegion.trailingAnchor),
            sourceListVC.view.bottomAnchor.constraint(equalTo: rightRegion.bottomAnchor),

            // Each sub-entry placeholder fills the whole region, same as the properties/involved-nets/
            // source-list trio combined -- only one of the 4 is ever visible at a time.
            geometryVC.view.topAnchor.constraint(equalTo: rightRegion.topAnchor),
            geometryVC.view.leadingAnchor.constraint(equalTo: rightRegion.leadingAnchor),
            geometryVC.view.trailingAnchor.constraint(equalTo: rightRegion.trailingAnchor),
            geometryVC.view.bottomAnchor.constraint(equalTo: rightRegion.bottomAnchor),

            simulationResultsVC.view.topAnchor.constraint(equalTo: rightRegion.topAnchor),
            simulationResultsVC.view.leadingAnchor.constraint(equalTo: rightRegion.leadingAnchor),
            simulationResultsVC.view.trailingAnchor.constraint(equalTo: rightRegion.trailingAnchor),
            simulationResultsVC.view.bottomAnchor.constraint(equalTo: rightRegion.bottomAnchor),

            fieldViewerVC.view.topAnchor.constraint(equalTo: rightRegion.topAnchor),
            fieldViewerVC.view.leadingAnchor.constraint(equalTo: rightRegion.leadingAnchor),
            fieldViewerVC.view.trailingAnchor.constraint(equalTo: rightRegion.trailingAnchor),
            fieldViewerVC.view.bottomAnchor.constraint(equalTo: rightRegion.bottomAnchor),
        ])
    }

    /// Restores the project/board picker header and net lists for a document that was opened from
    /// disk with a board already linked (config.kicadPcbPath set by a previous session's
    /// importBoard/projectSelected). Without this, buildUI() only ever left the header in its
    /// freshly-created, nothing-picked state -- projectPathField/boardPopUp are local UI state, not
    /// derived from the document, so simply having a saved kicadPcbPath never reached them on its
    /// own, and propertiesVC/sourceListVC's net lists are populated only by importSucceeded, which
    /// never runs on a plain reopen either. There's no saved .kicad_pro path to restore from --
    /// config only stores the .kicad_pcb (see EMSConfigBridge.kicadPcbPath's doc comment) -- so the
    /// project/board sibling scan below is reseeded from the linked .kicad_pcb's own directory,
    /// exactly mirroring projectSelected's scan just starting from the other file type.
    private func restoreLinkedBoardIfNeeded() {
        guard let kicadPcbPath = ownerDocument.config.kicadPcbPath else { return }
        let pcbURL = URL(fileURLWithPath: kicadPcbPath)
        let directory = pcbURL.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []

        let projectURL = siblings.first { $0.pathExtension == "kicad_pro" }
        projectPathField.stringValue = (projectURL ?? pcbURL).lastPathComponent

        let siblingPCBs = siblings.filter { $0.pathExtension == "kicad_pcb" }
        boardCandidates = siblingPCBs
        boardPopUp.removeAllItems()
        if siblingPCBs.isEmpty {
            // The linked .kicad_pcb itself is always a legitimate choice even if, for whatever
            // reason, it didn't turn up in its own directory listing (e.g. removable/network volume
            // hiccup) -- falling back to just it keeps the picker functional rather than stuck on
            // "No .kicad_pcb found" next to a board that's demonstrably already linked.
            boardCandidates = [pcbURL]
            boardPopUp.addItem(withTitle: pcbURL.lastPathComponent)
        } else {
            boardPopUp.addItems(withTitles: siblingPCBs.map { $0.lastPathComponent })
        }
        boardPopUp.isEnabled = true
        boardPopUp.isHidden = false
        if let currentIndex = boardCandidates.firstIndex(where: { $0.path == pcbURL.path }) {
            boardPopUp.selectItem(at: currentIndex)
        }
        statusLabel.stringValue = "Linked \(pcbURL.lastPathComponent)."

        propertiesViewController?.refreshNetLists()
        sourceListViewController?.refreshBoardData()
    }

    @objc private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let kicadProType = UTType(filenameExtension: "kicad_pro") {
            panel.allowedContentTypes = [kicadProType]
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.projectSelected(url)
        }
    }
    
    private func projectSelected(_ url: URL) {
        projectPathField.stringValue = url.lastPathComponent

        let directory = url.deletingLastPathComponent()
        let siblingPCBs =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "kicad_pcb" } ?? []
        boardCandidates = siblingPCBs

        boardPopUp.removeAllItems()
        if siblingPCBs.isEmpty {
            boardPopUp.addItem(withTitle: "No .kicad_pcb found next to this project")
            boardPopUp.isEnabled = false
            statusLabel.stringValue = "No board file found alongside \"\(url.lastPathComponent)\"."
            return
        }
        boardPopUp.addItems(withTitles: siblingPCBs.map { $0.lastPathComponent })
        boardPopUp.isEnabled = true
        statusLabel.stringValue = ""

        // The common case (one board per project) skips the extra click.
        if siblingPCBs.count == 1 {
            importBoard(siblingPCBs[0])
        }
    }

    @objc private func boardSelected() {
        let index = boardPopUp.indexOfSelectedItem
        guard index >= 0, index < boardCandidates.count else { return }
        importBoard(boardCandidates[index])
    }

    private func importBoard(_ boardURL: URL) {
        let doc = ownerDocument

        statusLabel.stringValue = "Linking \(boardURL.lastPathComponent)…"
        progressIndicator.startAnimation(nil)
        projectPathField.isEnabled = false
        boardPopUp.isEnabled = false

        let config = doc.config
        let helperPath = AppPaths.kicadQueryHelperPath

        // Just a stackup query against boardURL directly (see KicadBoardBridge.linkKicadPCB's doc
        // comment) -- no kicad-cli export, no copy into the document, so this doesn't touch the
        // filesystem at all and works whether or not the document has ever been saved. Still a
        // real subprocess round trip (shells out to the query helper), so kept off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try KicadBoardBridge.linkKicadPCB(boardURL.path, config: config, kicadQueryHelperPath: helperPath)
                // Fetched here (already off the main thread) rather than in importSucceeded, so the
                // ground-net guess below has real data to work with instead of a second async hop.
                let nets = (try? KicadBoardBridge.allNets(forBoard: boardURL.path,
                                                            kicadQueryHelperPath: helperPath)) ?? []
                DispatchQueue.main.async {
                    self?.importSucceeded(boardURL: boardURL, document: doc, availableNets: nets)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.importFailed(error: error)
                }
            }
        }
    }

    private func importSucceeded(boardURL: URL, document: Document, availableNets: [String]) {
        progressIndicator.stopAnimation(nil)
        projectPathField.isEnabled = true
        boardPopUp.isEnabled = true
        statusLabel.stringValue = "Linked \(boardURL.lastPathComponent)."
        document.updateChangeCount(.changeDone)
        propertiesViewController?.refreshNetLists()
        sourceListViewController?.refreshBoardData()
        simulationListViewController?.setProjectAvailable(true)

        // A fresh simulation for every successfully linked board, named after it -- picking the
        // same board again (or a different board that happens to share a name) just gets a
        // deduplicated suffix rather than colliding with or replacing the existing one.
        let baseName = "\(Self.titleCased(boardURL.deletingPathExtension().lastPathComponent)) Sim"
        let existingNames = Set(document.config.simulations.map { $0.name })
        var simulationName = baseName
        var suffix = 2
        while existingNames.contains(simulationName) {
            simulationName = "\(baseName) \(suffix)"
            suffix += 1
        }
        let simulation = document.config.addSimulationNamed(simulationName)
        if let groundNetGuess = GroundNetHeuristic.bestGuess(among: availableNets) {
            simulation.groundNetKind = .net
            simulation.groundNetName = groundNetGuess
        }
        simulationListViewController?.simulationAddedExternally(at: document.config.simulations.count - 1)
    }

    private func importFailed(error: Error) {
        progressIndicator.stopAnimation(nil)
        projectPathField.isEnabled = true
        boardPopUp.isEnabled = true
        statusLabel.stringValue = "Link failed: \(error.localizedDescription)"
    }

    private static func titleCased(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}
