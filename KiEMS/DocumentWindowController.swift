import Cocoa
import UniformTypeIdentifiers

/// A document's window: the simulation source list, the editor content for whatever is selected in
/// it, and a toolbar holding the run/run all/pause buttons and an Xcode-style status display -- which
/// also carries the KiCad project/board picker.
final class DocumentWindowController: NSWindowController {
    // Set explicitly at init, not read back via the inherited `document` property: that property
    // is only guaranteed to be set by NSDocument.addWindowController(_:) *after* this object has
    // already been fully constructed, and windowDidLoad() has no documented ordering guarantee
    // relative to it either -- building the UI against `currentDocument` there silently produced a
    // completely empty window whenever windowDidLoad() ran first (a `guard let doc = ... else {
    // return }` bailed out of buildUI() before anything was ever added to contentView). Taking the
    // document as a constructor parameter instead removes the race entirely.
    private let ownerDocument: Document
    /// Every restoreSavedResults loop runs here, one at a time: a report's loop releases each
    /// simulation as it goes, which would free a pipeline's results while an overlapping loop (the
    /// one started on open) was reading them on the main thread.
    private let restoreQueue = DispatchQueue(label: "KiEMS.restoreSavedResults", qos: .userInitiated)

    private let statusView = ToolbarStatusView()
    private var projectPathField: NSPathControl { statusView.projectPathControl }
    private var projectSelectionButton: NSButton { statusView.projectSelectionButton }
    private var boardPopUp: NSPopUpButton { statusView.boardPopUp }
    /// The status display's message while none of this document's jobs is running -- the outcome of
    /// the last board link or run, as Xcode shows its last build's.
    private var lastEventMessage = ""
    /// A board link in progress -- spins the status display's activity indicator.
    private var isLinking = false
    private var runItem: NSToolbarItem?
    private var runAllItem: NSToolbarItem?
    private var pauseItem: NSToolbarItem?
    /// The source list's selection, kept for the run buttons and issue navigation.
    private var currentSelection: SimulationListSelection?
    private let mainContentLoadingIndicator = NSProgressIndicator()
    private var simulationListViewController: SimulationListViewController?
    /// Source list (sidebar) | editor. A real split-view sidebar is what lets the source list's
    /// glass panel run up through the toolbar, with the run buttons on it, as in Xcode.
    private let splitViewController = NSSplitViewController()
    private var propertiesViewController: SimulationPropertiesViewController?
    private var wholeBoardViewController: WholeBoardViewController?

    /// Edit > Find… -- see WholeBoardViewController.showFindPanel().
    @objc func showFindPanel(_ sender: Any?) {
        wholeBoardViewController?.showFindPanel()
    }

    /// See WholeBoardViewController.populateItemMenu(_:) -- called by AppDelegate's Item menu.
    func populateItemMenu(_ menu: NSMenu) {
        wholeBoardViewController?.populateItemMenu(menu)
    }
    private var sourceListViewController: SourceListViewController?
    private var geometryViewController: GeometryViewController?
    private var simulationResultsViewController: SimulationResultsViewController?
    private var fieldViewerViewController: FieldViewerViewController?
    private var noSelectionLabel: NSTextField?
    /// Kept in sync by simulationListVC.onSelectionChanged -- sourceListVC.onInvolvedNetsChanged
    /// needs to know which simulation to invalidate the geometry cache for, but doesn't carry that
    /// index itself (it fires for whichever simulation SourceListViewController is currently
    /// editing, which is always this one).
    private var currentSimulationIndex: Int?
    private var isLoadingBoard = false
    /// Set when the linked KiCad files changed on disk; the board-derived views are reloaded only
    /// once geometry is next regenerated -- see handleLinkedKicadFilesChanged().
    private var hasPendingBoardReload = false

    private var boardCandidates: [URL] = []
    private let kicadFileWatcher = KicadFileWatcher()
    /// Why restoreSavedResults couldn't prepare a simulation, by name -- see reportEntry.
    private var restoreErrors: [String: String] = [:]

    init(document: Document) {
        ownerDocument = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
            // Full-size content so the source list's glass card can run up under the title bar.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "KiEMS Simulation"
        // The status display says what's open; the title would only crowd the toolbar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // A unified toolbar is what makes the title bar double height.
        window.toolbarStyle = .unified
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "KiEMSDocumentToolbar")
        toolbar.delegate = self
        window.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.statusDisplay]
        window.toolbar = toolbar
        buildUI()
        window.center()
        restoreSavedStatuses()
    }

    private static let minimumSidebarWidth: CGFloat = 230
    private static let initialSidebarWidth: CGFloat = 240
    private static let maximumSidebarWidth: CGFloat = 420
    private var hasAppliedInitialSidebarWidth = false

    /// The split view ignores a divider position set before its first real layout.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !hasAppliedInitialSidebarWidth else { return }
        hasAppliedInitialSidebarWidth = true
        splitViewController.splitView.layoutSubtreeIfNeeded()
        // Wide enough for the longest simulation name, within the sidebar's limits.
        let fitted = simulationListViewController?.preferredSidebarWidth() ?? Self.initialSidebarWidth
        let width = min(max(fitted, Self.initialSidebarWidth), Self.maximumSidebarWidth)
        splitViewController.splitView.setPosition(width, ofDividerAt: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        chooseProject()
    }

    /// Jumps the main UI to the simulation+sub-entry a given job represents -- the Jobs window's
    /// double-click-to-jump gesture. Resolves the simulation by name against the current config (a
    /// job's simulationName is captured at request time, so a since-renamed simulation simply isn't
    /// found and nothing happens) and selects the matching Geometry / Simulation Results / Field
    /// Viewer entry, which fires the list's onSelectionChanged to actually show it.
    func selectJob(kind: JobKind, forSimulationNamed simulationName: String) {
        guard let index = ownerDocument.config.simulations.firstIndex(where: { $0.name == simulationName }) else { return }
        let selection: SimulationListSelection
        switch kind {
        case .geometryGeneration:
            selection = .geometry(simulationIndex: index)
        case .simulation:
            selection = .simulationResults(simulationIndex: index)
        case .fieldPostProcessing:
            selection = .fieldViewer(simulationIndex: index)
        }
        simulationListViewController?.select(selection)
    }
    
    private func buildUI() {
        guard let window else { return }
        // Everything right of the sidebar.
        let editorViewController = NSViewController()
        let editorView = NSView()
        editorViewController.view = editorView

        kicadFileWatcher.onChange = { [weak self] in self?.handleLinkedKicadFilesChanged() }

        projectSelectionButton.target = self
        projectSelectionButton.action = #selector(chooseProject)
        boardPopUp.target = self
        boardPopUp.action = #selector(boardSelected)
        boardPopUp.isEnabled = false
        boardPopUp.addItem(withTitle: "Select a board…")
        statusView.onShowErrors = { [weak self] in self?.showNextIssue(errors: true) }
        statusView.onShowWarnings = { [weak self] in self?.showNextIssue(errors: false) }
        JobScheduler.shared.addChangeObserver { [weak self] in
            self?.updateToolbarItems()
            self?.refreshStatusDisplay()
        }

        let propertiesVC = SimulationPropertiesViewController(document: ownerDocument)
        propertiesViewController = propertiesVC

        // Replaces the old involved-nets/source-list configuration duo outright (see
        // WholeBoardViewController's own doc comment) -- sourceListVC below is still instantiated
        // and wired (its own non-UI logic, e.g. cache invalidation, is unaffected), just never
        // unhidden any more. propertiesVC is different: still the exact same settings panel, just
        // reparented into wholeBoardVC's own info column instead of sitting above sourceListVC --
        // see WholeBoardViewController.loadView()'s own comment on where its view actually ends up.
        let wholeBoardVC = WholeBoardViewController(document: ownerDocument, propertiesViewController: propertiesVC)
        wholeBoardViewController = wholeBoardVC

        // Each simulation's 3 outline sub-entries (Geometry/Simulation Results/Field Viewer) present
        // one of these instead of the properties/involved-nets/source-list trio -- see
        // simulationListVC.onSelectionChanged below.
        let geometryVC = GeometryViewController(document: ownerDocument)
        geometryViewController = geometryVC

        let sourceListVC = SourceListViewController(document: ownerDocument)
        sourceListViewController = sourceListVC
        // See includedToggled's own doc comment. A net's
        // membership/impedance/plane/width also change what the geometry step actually builds
        // (port placement, hull extent), so a stale cached geometry/error from before the edit
        // can't keep being shown either -- see GeometryViewController.invalidateCache's own doc
        // comment. (This also fires for excitation-only edits, e.g. start time/phase, which don't
        // actually change the geometry -- an unnecessary cache clear there, not an incorrect one:
        // worst case is one avoidable re-run next time Geometry is opened.)
        let simulationResultsVC = SimulationResultsViewController(document: ownerDocument)
        simulationResultsViewController = simulationResultsVC
        let configurationChanged = { [weak self] in
            if let self, let index = self.currentSimulationIndex {
                // All 3 rows: an involved-nets edit can change the geometry step's own output (port
                // placement, hull extent), which invalidates .simulation (and therefore
                // .fieldPostProcessing, which has no cache of its own -- see JobKind's own doc
                // comment) too.
                self.invalidate(simulationIndex: index, reason: "Simulated nets changed", includingGeometry: true)
            }
            // Excitations may have been added/removed/edited, which changes the panel's
            // main-excitation duration.
            self?.propertiesViewController?.excitationsEditedElsewhere()
        }
        sourceListVC.onInvolvedNetsChanged = configurationChanged
        wholeBoardVC.onConfigurationChanged = configurationChanged
        // Board Setup edits the document's own frequency range, the same one the simulation settings
        // show -- so it invalidates results exactly as an edit there would.
        wholeBoardVC.onBoardFrequencyRangeChanged = { [weak propertiesVC] in
            propertiesVC?.onFDTDParametersChanged?("Frequency range changed")
        }
        // Wired before simulationListVC's view loads: its initial selection callback can start the
        // board load (via wholeBoardVC.refresh()), and a load started with nobody listening never
        // shows the spinner -- the board view was revealed, interactive, before anything loaded.
        wholeBoardVC.onLoadingStateChanged = { [weak self] isLoading in
            self?.setBoardLoading(isLoading)
        }
        let fieldViewerVC = FieldViewerViewController(document: ownerDocument)
        fieldViewerViewController = fieldViewerVC

        // Force these views to load (running their buildUI()) before simulationListVC's view is
        // touched below -- simulationListVC's loadView() fires its initial selection callback
        // synchronously, which reaches into propertiesVC/sourceListVC's UI. If their own loadView()
        // hadn't run yet, that callback would hit not-yet-built controls (e.g. SourceListViewController's
        // `excitationFieldsContainer: NSStackView!`, still nil) and crash.
        _ = propertiesVC.view
        _ = wholeBoardVC.view
        _ = sourceListVC.view
        _ = geometryVC.view
        _ = simulationResultsVC.view
        _ = fieldViewerVC.view
        propertiesVC.view.translatesAutoresizingMaskIntoConstraints = false
        wholeBoardVC.view.translatesAutoresizingMaskIntoConstraints = false
        sourceListVC.view.translatesAutoresizingMaskIntoConstraints = false
        geometryVC.view.translatesAutoresizingMaskIntoConstraints = false
        simulationResultsVC.view.translatesAutoresizingMaskIntoConstraints = false
        fieldViewerVC.view.translatesAutoresizingMaskIntoConstraints = false
        geometryVC.view.isHidden = true
        simulationResultsVC.view.isHidden = true
        fieldViewerVC.view.isHidden = true

        // Shown instead of wholeBoardVC.view whenever nothing is selected -- see
        // simulationListVC.onSelectionChanged below.
        let noSelectionLabel = NSTextField(labelWithString: "No Simulation Selected")
        noSelectionLabel.font = .systemFont(ofSize: 28, weight: .medium)
        noSelectionLabel.textColor = .tertiaryLabelColor
        noSelectionLabel.alignment = .center
        noSelectionLabel.translatesAutoresizingMaskIntoConstraints = false
        self.noSelectionLabel = noSelectionLabel

        let simulationListVC = SimulationListViewController(document: ownerDocument)
        simulationListViewController = simulationListVC
        // Reopening a document that already has a board linked -- add/remove should already be
        // usable, not just after a fresh link this session.
        simulationListVC.setProjectAvailable(ownerDocument.config.kicadPcbPath != nil)
        // ...and the picker header/net lists need to reflect that too -- restoreLinkedBoardIfNeeded
        // is everything importSucceeded does *except* the two actions that only make sense the
        // moment a board is first linked (adding a new simulation, re-running link(toConfig:) itself).
        restoreLinkedBoardIfNeeded()
        // Renaming a simulation has no other way to reach the sidebar row showing its (now stale) name.
        propertiesVC.onNameChanged = { [weak simulationListVC] in simulationListVC?.refreshRows() }
        // ...and the reverse: a rename made directly in the sidebar (see SimulationNameField) has no
        // other way to reach propertiesVC's own name field if it's showing that same simulation.
        simulationListVC.onSimulationAdded = { [weak wholeBoardVC] index in
            wholeBoardVC?.applyBoardInclusions(toSimulationAt: index)
        }
        wholeBoardVC.onSimulationSetChanged = { [weak self] templateIndex in
            self?.regenerateSimulationSet(atTemplateIndex: templateIndex, reason: nil)
        }
        simulationListVC.onSimulationRenamed = { [weak self, weak propertiesVC] index in
            propertiesVC?.refreshNameFieldIfSelected(index: index)
            // Set-generated names include the template name, so renaming a set is itself a
            // regeneration just as changing its pin pattern is.
            guard let self, self.isSimulationSetTemplate(at: index) else { return }
            self.regenerateSimulationSet(atTemplateIndex: index, reason: nil)
        }
        // See SimulationPropertiesViewController.onGeometryParametersChanged's own doc comment --
        // a hull-padding/via/ground-net edit invalidates whichever simulation it belongs to. A
        // Simulation Set template is never run: its edit reaches its generated simulations by
        // regenerating them.
        propertiesVC.onGeometryParametersChanged = { [weak self, weak wholeBoardVC] index, reason in
            guard let self else { return }
            if self.isSimulationSetTemplate(at: index) {
                self.regenerateSimulationSet(atTemplateIndex: index, reason: reason)
            } else {
                // See onInvolvedNetsChanged's identical comment on why all 3 rows.
                self.invalidate(simulationIndex: index, reason: reason, includingGeometry: true)
            }
            // Hull padding changes the fast region highlight, while padding/inset/spacing all
            // change Setup's asynchronous stitching-via plan -- see
            // WholeBoardViewController.refreshActivityHighlight().
            wholeBoardVC?.refreshActivityHighlight()
        }
        // See SimulationPropertiesViewController.onFDTDParametersChanged's own doc comment -- unlike
        // onGeometryParametersChanged above, this only touches simulation results (max. timesteps
        // doesn't affect the geometry step's output at all), and for every simulation in the document
        // at once, since it's a document-level setting rather than a per-simulation one.
        propertiesVC.onFDTDParametersChanged = { [weak self] reason in
            guard let self else { return }
            for index in self.ownerDocument.config.simulations.indices {
                // Geometry itself is untouched by an FDTD-only parameter -- only .simulation/
                // .fieldPostProcessing go invalid (see onInvolvedNetsChanged's identical comment on
                // why the latter tags along with the former).
                self.invalidate(simulationIndex: index, reason: reason, includingGeometry: false)
            }
        }
        propertiesVC.onResultsParametersChanged = { [weak self, weak simulationResultsVC] index in
            guard let self else { return }
            if self.isSimulationSetTemplate(at: index) {
                self.simulationSetAnalysisChanged(atTemplateIndex: index)
                return
            }
            simulationResultsVC?.eyeSettingsChanged(forSimulationIndex: index)
            self.refreshEyeTestStatus(forSimulationIndex: index)
        }
        wholeBoardVC.onSimulationSetEyeTestChanged = { [weak self] templateIndex in
            self?.simulationSetAnalysisChanged(atTemplateIndex: templateIndex)
        }
        // See GeometryViewController.onRunStateChanged's doc comment -- the spinner next to a
        // simulation's "Geometry" row has no other way to know a background pipeline run started/
        // finished for it.
        geometryVC.onRunStateChanged = { [weak self, weak simulationListVC] index, isRunning in
            if isRunning { self?.applyPendingBoardReload() }
            simulationListVC?.setBusy(isRunning, forSimulationIndex: index, kind: .geometryGeneration)
        }
        // Deliberately no equivalent relay of simulationResultsVC.onRunStateChanged here -- that
        // fires as soon as the *combined* run starts, before it's known whether the Simulation
        // Results stage itself has actually begun (it computes geometry first). The "Simulation
        // Results" row's own .inProgress transition instead comes only from onProgressChanged's
        // .simulation-phase case below, via setProgress(...,kind: .simulation) -- see setBusy's own
        // doc comment.
        //
        // Drives the "Geometry" row's own progress fraction while GeometryViewController's own run
        // is in flight (selecting the Geometry row directly).
        geometryVC.onProgressChanged = { [weak simulationListVC] index, progress in
            simulationListVC?.setProgress(progress.fraction, forSimulationIndex: index, kind: .geometryGeneration)
        }
        // simulationResultsVC's own ensureStage:.results run computes geometry/grid as an
        // unavoidable first step (see EMSPipelineProgressPhase's own doc comment) -- reuse the
        // "Geometry" row to show that part of the same run too, then switch to the "Simulation
        // Results" row's own progress once the FDTD phase begins. Since geometryVC itself isn't the
        // one running here, its row's busy state is driven directly rather than via onRunStateChanged.
        simulationResultsVC.onProgressChanged = { [weak self, weak simulationListVC] index, progress in
            switch progress.phase {
            case .geometry:
                self?.applyPendingBoardReload()
                simulationListVC?.setBusy(true, forSimulationIndex: index, kind: .geometryGeneration)
                simulationListVC?.setProgress(progress.fraction, forSimulationIndex: index, kind: .geometryGeneration)
            case .settingUp, .simulation:
                // Reaching either of these phases at all means geometry itself already succeeded.
                // .settingUp's own `fraction` is always 0 (openEMS gives no real progress signal for
                // it -- see EMSPipelineProgressPhase's own doc comment), so the row's own progress
                // ring just sits at 0% (still correctly showing "busy") for that portion -- the real,
                // ticking countdown lives in SimulationResultsViewController's own bigger status view.
                simulationListVC?.setCompleted(true, forSimulationIndex: index, kind: .geometryGeneration)
                simulationListVC?.setProgress(progress.fraction, forSimulationIndex: index, kind: .simulation)
            @unknown default:
                break
            }
        }
        // See GeometryViewController.onRunFinished's doc comment -- swaps the "Geometry" row's
        // circular progress ring for its green/yellow succeeded/failed status icon.
        geometryVC.onRunFinished = { [weak simulationListVC] index, success in
            simulationListVC?.setCompleted(success, forSimulationIndex: index, kind: .geometryGeneration)
        }
        // simulationResultsVC's own run can fail in either its geometry or simulation phase (see its
        // onRunFinished's own doc comment) -- attribute the outcome to whichever row was actually in
        // flight when it stopped. A failure during .geometry never reached the Simulation Results row
        // at all, so that row is left untouched (still .invalid).
        simulationResultsVC.onRunFinished = { [weak self, weak simulationListVC] index, reachedPhase, success in
            self?.showRunOutcome(forSimulationIndex: index, success: success)
            switch reachedPhase {
            case .geometry:
                simulationListVC?.setCompleted(success, forSimulationIndex: index, kind: .geometryGeneration)
            case .settingUp, .simulation:
                simulationListVC?.setCompleted(true, forSimulationIndex: index, kind: .geometryGeneration)
                if success {
                    self?.refreshEyeTestStatus(forSimulationIndex: index)
                }
                simulationListVC?.setCompleted(success, forSimulationIndex: index, kind: .simulation)
                // Field post-processing is near-instant once .results exists (see JobKind's own doc
                // comment), so a finished simulation means the Field Viewer is ready too.
                if success {
                    simulationListVC?.setCompleted(true, forSimulationIndex: index, kind: .fieldPostProcessing)
                }
            @unknown default:
                break
            }
        }
        // A job cancelled (via the Jobs window) rather than genuinely failed -- revert whichever
        // row(s) were showing progress back to "invalid" instead of the yellow failed state
        // onRunFinished(_:_:false) would otherwise show. See GeometryViewController.onRunCancelled's
        // own doc comment.
        geometryVC.onRunCancelled = { [weak self] index in
            self?.resetRow(forSimulationIndex: index, kind: .geometryGeneration)
        }
        simulationResultsVC.onRunCancelled = { [weak self, weak simulationListVC] index, reachedPhase in
            switch reachedPhase {
            case .geometry:
                self?.resetRow(forSimulationIndex: index, kind: .geometryGeneration)
                self?.resetRow(forSimulationIndex: index, kind: .simulation)
            case .settingUp, .simulation:
                // Geometry genuinely finished before the .settingUp/.simulation-phase job was
                // cancelled -- leave that row showing "succeeded", only reset the Simulation Results one.
                simulationListVC?.setCompleted(true, forSimulationIndex: index, kind: .geometryGeneration)
                self?.resetRow(forSimulationIndex: index, kind: .simulation)
            @unknown default:
                break
            }
        }
        // FieldViewerViewController watches all 3 of a simulation's own prerequisite jobs (see its
        // own onRunStateChanged doc comment for why), so every callback below fires for
        // .geometryGeneration/.simulation progress too, not just .fieldPostProcessing -- those rows
        // are already correctly driven by geometryVC/simulationResultsVC's own wiring above, so only
        // relay a `.fieldPostProcessing`-kind report into the sidebar's own Field Viewer row here.
        // Forwarding every kind unfiltered (the previous behavior) was a real bug: a geometry-phase
        // progress report made the Field Viewer row's own indicator fill up while geometry was still
        // building, with no simulation/field work having started at all.
        fieldViewerVC.onRunCancelled = { [weak simulationListVC] index, kind in
            guard kind == .fieldPostProcessing else { return }
            simulationListVC?.setInvalid(forSimulationIndex: index, kind: kind)
        }
        fieldViewerVC.onRunStateChanged = { [weak simulationListVC] index, kind, isRunning in
            guard kind == .fieldPostProcessing else { return }
            simulationListVC?.setBusy(isRunning, forSimulationIndex: index, kind: kind)
        }
        fieldViewerVC.onProgressChanged = { [weak simulationListVC] index, kind, progress in
            guard kind == .fieldPostProcessing else { return }
            simulationListVC?.setProgress(progress.fraction, forSimulationIndex: index, kind: kind)
        }
        fieldViewerVC.onRunFinished = { [weak simulationListVC] index, kind, success in
            guard kind == .fieldPostProcessing else { return }
            simulationListVC?.setCompleted(success, forSimulationIndex: index, kind: kind)
        }
        simulationListVC.onGenerateGeometry = { [weak geometryVC] index in
            geometryVC?.generateGeometry(forSimulationIndex: index)
        }
        simulationListVC.onRunSimulation = { [weak simulationResultsVC] index in
            simulationResultsVC?.runSimulation(forSimulationIndex: index)
        }
        // Same as File > Regenerate Geometry / Reset Results, but for just the clicked simulation.
        simulationListVC.onInvalidate = { [weak self] index, includingGeometry in
            self?.invalidate(simulationIndex: index, reason: nil, includingGeometry: includingGeometry)
            self?.fieldViewerViewController?.invalidateCache(forSimulationIndex: index)
        }
        simulationListVC.onSelectionChanged = { [weak self] selection in
            guard let self else { return }
            self.currentSelection = selection
            self.updateToolbarItems()

            // The outline owns a valid initial selection before the linked board's asynchronous
            // preview exists. Retain that selection, but never reveal any of its content until the
            // load callback below removes the main-pane spinner.
            guard !self.isLoadingBoard else { return }

            // Exactly one of these 4 is shown at a time -- selecting a simulation itself shows the
            // properties/whole-board/source-list trio; selecting one of its 3 sub-entries shows that
            // entry's own view controller instead, filling the same region. setSelectedSimulationIndex
            // is only called on the trio for the .simulation case, not unconditionally for every case.
            var showsSimulationDetail = false
            var showsGeometry = false
            var showsSimulationResults = false
            var showsFieldViewer = false
            switch selection {
            case .boardSetup:
                // The same whole-board view, editing the board-wide defaults instead of a simulation.
                showsSimulationDetail = true
                self.currentSimulationIndex = nil
                self.wholeBoardViewController?.setBoardSetupMode(true)
                self.wholeBoardViewController?.setSelectedSimulationIndex(nil)
                self.wholeBoardViewController?.refresh()
            case .simulation(let index):
                showsSimulationDetail = true
                self.currentSimulationIndex = index
                self.propertiesViewController?.setSelectedSimulationIndex(index)
                self.wholeBoardViewController?.setBoardSetupMode(false)
                self.wholeBoardViewController?.setSelectedSimulationIndex(index)
                self.wholeBoardViewController?.refresh()
                self.sourceListViewController?.setSelectedSimulationIndex(index)
            case .geometry(let index):
                showsGeometry = true
                self.geometryViewController?.showGeometry(forSimulationIndex: index)
            case .simulationResults(let index):
                showsSimulationResults = true
                self.simulationResultsViewController?.showResults(forSimulationIndex: index)
            case .fieldViewer(let index):
                showsFieldViewer = true
                self.fieldViewerViewController?.showField(forSimulationIndex: index)
            case nil:
                self.currentSimulationIndex = nil
                self.propertiesViewController?.setSelectedSimulationIndex(nil)
                self.wholeBoardViewController?.setSelectedSimulationIndex(nil)
                self.sourceListViewController?.setSelectedSimulationIndex(nil)
            }

            // sourceListVC is never shown any more -- wholeBoardVC fills this whole case's region
            // alone. Still instantiated and wired (not ripped out) since nothing about its own
            // non-UI logic was wrong -- just permanently unreachable now that nothing ever unhides
            // its view. propertiesVC.view is different: it's reparented inside wholeBoardVC's own
            // info column now (see WholeBoardViewController.loadView()), so *it* toggles
            // propertiesVC.view.isHidden itself, based on whether anything's selected on the board
            // -- touching it here too would just race with that.
            if self.isLoadingBoard {
                // refresh() can begin during the selection callback above; do not let the normal
                // visibility update at the end of this callback undo the loading overlay it just set.
                self.wholeBoardViewController?.view.isHidden = true
                self.sourceListViewController?.view.isHidden = true
                self.geometryViewController?.view.isHidden = true
                self.simulationResultsViewController?.view.isHidden = true
                self.fieldViewerViewController?.view.isHidden = true
                self.fieldViewerViewController?.setViewerVisible(false)
                self.noSelectionLabel?.isHidden = true
            } else {
                self.wholeBoardViewController?.view.isHidden = !showsSimulationDetail
                self.sourceListViewController?.view.isHidden = true
                self.geometryViewController?.view.isHidden = !showsGeometry
                self.simulationResultsViewController?.view.isHidden = !showsSimulationResults
                self.fieldViewerViewController?.view.isHidden = !showsFieldViewer
                self.fieldViewerViewController?.setViewerVisible(showsFieldViewer)
                self.noSelectionLabel?.isHidden = selection != nil
            }
        }
        // Set before the list's view loads: loading it builds the rows, which already reports.
        simulationListVC.onStatusChanged = { [weak self] in
            self?.updateToolbarItems()
            self?.refreshIssueCounts()
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: simulationListVC)
        // Wide enough for the traffic lights and all three run buttons; narrower pushes Pause into
        // the toolbar's overflow menu.
        sidebarItem.minimumThickness = Self.minimumSidebarWidth
        sidebarItem.maximumThickness = Self.maximumSidebarWidth
        sidebarItem.canCollapse = false
        let editorItem = NSSplitViewItem(viewController: editorViewController)
        // Leaves the editor enough room to stay useful.
        editorItem.minimumThickness = 320
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(editorItem)
        // Installing a content view controller resizes the window to fit it; keep the window's own
        // size. The sidebar's starting width is applied once the window is on screen (showWindow).
        let frame = window.frame
        window.contentViewController = splitViewController
        window.setFrame(frame, display: false)
        NotificationCenter.default.addObserver(self, selector: #selector(sidebarDidResize(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification,
                                               object: splitViewController.splitView)
        sidebarDidResize(nil)

        // An invisible container spanning the whole area right of the sidebar, purely so
        // noSelectionLabel can be centered in that region rather than in the whole window (which
        // would put it off-center, since the sidebar eats the left 220pt).
        let rightRegion = NSView()
        rightRegion.translatesAutoresizingMaskIntoConstraints = false

        mainContentLoadingIndicator.style = .spinning
        mainContentLoadingIndicator.controlSize = .large
        mainContentLoadingIndicator.isDisplayedWhenStopped = false
        mainContentLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        mainContentLoadingIndicator.isHidden = true

        editorView.addSubview(rightRegion)
        rightRegion.addSubview(wholeBoardVC.view)
        rightRegion.addSubview(sourceListVC.view)
        rightRegion.addSubview(geometryVC.view)
        rightRegion.addSubview(simulationResultsVC.view)
        rightRegion.addSubview(fieldViewerVC.view)
        rightRegion.addSubview(noSelectionLabel)
        editorView.addSubview(mainContentLoadingIndicator)

        // The editor pane runs under the title bar (.fullSizeContentView); its safe area starts
        // below the toolbar.
        NSLayoutConstraint.activate([
            rightRegion.topAnchor.constraint(equalTo: editorView.safeAreaLayoutGuide.topAnchor),
            rightRegion.leadingAnchor.constraint(equalTo: editorView.leadingAnchor),
            rightRegion.trailingAnchor.constraint(equalTo: editorView.trailingAnchor),
            rightRegion.bottomAnchor.constraint(equalTo: editorView.bottomAnchor),

            noSelectionLabel.centerXAnchor.constraint(equalTo: rightRegion.centerXAnchor),
            noSelectionLabel.centerYAnchor.constraint(equalTo: rightRegion.centerYAnchor),

            mainContentLoadingIndicator.centerXAnchor.constraint(equalTo: editorView.centerXAnchor),
            mainContentLoadingIndicator.centerYAnchor.constraint(equalTo: rightRegion.centerYAnchor),

            // wholeBoardVC.view now fills the *whole* region, same as geometryVC.view/
            // simulationResultsVC.view/fieldViewerVC.view below -- it replaces the entire old
            // involved-nets/source-list duo, not just a strip above it. propertiesVC.view is no
            // longer positioned here at all -- see WholeBoardViewController.loadView()'s own
            // comment on where it actually lives now.
            wholeBoardVC.view.topAnchor.constraint(equalTo: rightRegion.topAnchor),
            wholeBoardVC.view.leadingAnchor.constraint(equalTo: rightRegion.leadingAnchor),
            wholeBoardVC.view.trailingAnchor.constraint(equalTo: rightRegion.trailingAnchor),
            wholeBoardVC.view.bottomAnchor.constraint(equalTo: rightRegion.bottomAnchor),

            // sourceListVC.view is always hidden now (see onSelectionChanged) -- this just keeps its
            // own internal layout non-conflicting, nothing user-visible.
            sourceListVC.view.topAnchor.constraint(equalTo: rightRegion.topAnchor),
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

        // A load the initial selection started above ran setBoardLoading(true) before every view
        // here existed; re-apply it now that they all do.
        if isLoadingBoard {
            setBoardLoading(true)
        }
        // On reopen, restoreLinkedBoardIfNeeded() has already reconstructed the picker state above;
        // this is the actual asynchronous KiCad parse/preview load whose completion gates the UI.
        if ownerDocument.config.kicadPcbPath != nil {
            wholeBoardVC.refresh()
        }
        updateToolbarItems()
        refreshStatusDisplay()
        refreshIssueCounts()
    }

    private func setBoardLoading(_ isLoading: Bool) {
        isLoadingBoard = isLoading
        simulationListViewController?.view.isHidden = isLoading
        mainContentLoadingIndicator.isHidden = !isLoading
        if isLoading {
            mainContentLoadingIndicator.startAnimation(nil)
            wholeBoardViewController?.view.isHidden = true
            sourceListViewController?.view.isHidden = true
            geometryViewController?.view.isHidden = true
            simulationResultsViewController?.view.isHidden = true
            fieldViewerViewController?.view.isHidden = true
            fieldViewerViewController?.setViewerVisible(false)
            noSelectionLabel?.isHidden = true
        } else {
            mainContentLoadingIndicator.stopAnimation(nil)
            simulationListViewController?.notifyCurrentSelection()
        }
        updateToolbarItems()
    }

    /// Restores the status display's project/board picker and net lists for a document that was
    /// opened from disk with a board already linked (config.kicadPcbPath set by a previous session's
    /// importBoard/projectSelected). Without this, buildUI() only ever left the picker in its
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

        let projectURL = Self.siblingProjectURL(among: siblings)
        statusView.setProjectURL(projectURL ?? pcbURL)

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
        statusView.setBoardVisible(true)
        if let currentIndex = boardCandidates.firstIndex(where: { $0.path == pcbURL.path }) {
            boardPopUp.selectItem(at: currentIndex)
        }
        showEvent("")

        propertiesViewController?.refreshNetLists()
        sourceListViewController?.refreshBoardData()
        kicadFileWatcher.startWatching(pcbPath: pcbURL.path, projectPath: projectURL?.path)
    }

    @objc private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard let kicadProjectType = UTType(filenameExtension: "kicad_pro"),
              let kicadPCBType = UTType(filenameExtension: "kicad_pcb") else { return }
        panel.allowedContentTypes = [kicadProjectType, kicadPCBType, .folder]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.projectSelected(url)
        }
    }
    
    private func projectSelected(_ url: URL) {
        let ext = url.pathExtension
        
        statusView.setBoardVisible(true)
        if ext == "kicad_pro" {
            statusView.setProjectURL(url)
            let directory = url.deletingLastPathComponent()
            let siblingPCBs =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "kicad_pcb" } ?? []
            boardCandidates = siblingPCBs
            
            boardPopUp.removeAllItems()
            if siblingPCBs.isEmpty {
                boardPopUp.addItem(withTitle: "No .kicad_pcb found next to this project")
                boardPopUp.isEnabled = false
                showEvent("No board file found alongside “\(url.lastPathComponent)”")
                return
            }
            boardPopUp.addItems(withTitles: siblingPCBs.map { $0.lastPathComponent })
            boardPopUp.isEnabled = true
            showEvent("")
            
            // The common case (one board per project) skips the extra click.
            if siblingPCBs.count == 1 {
                importBoard(siblingPCBs[0])
            }
        } else if ext == "kicad_pcb" {
            let directory = url.deletingLastPathComponent()
            let siblingProjects =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "kicad_pro" } ?? []
            let projectName = directory.lastPathComponent
            let projectUrl = siblingProjects.first(where: { $0.lastPathComponent == projectName }) ?? siblingProjects.first
            statusView.setProjectURL(projectUrl)

            let siblingPCBs =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "kicad_pcb" } ?? []
            boardCandidates = siblingPCBs
            
            boardPopUp.removeAllItems()
            boardPopUp.addItems(withTitles: siblingPCBs.map { $0.lastPathComponent })
            boardPopUp.isEnabled = true

            importBoard(url)
        } else {
            let directory = url
            let projects =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "kicad_pro" } ?? []
            let projectName = directory.lastPathComponent
            let projectUrl = projects.first(where: { $0.lastPathComponent == projectName }) ?? projects.first
            statusView.setProjectURL(projectUrl)
            
            let siblingPCBs =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "kicad_pcb" } ?? []
            boardCandidates = siblingPCBs
            
            boardPopUp.removeAllItems()
            boardPopUp.addItems(withTitles: siblingPCBs.map { $0.lastPathComponent })
            boardPopUp.isEnabled = true

            importBoard(url)
        }
    }

    @objc private func boardSelected() {
        let index = boardPopUp.indexOfSelectedItem
        guard index >= 0, index < boardCandidates.count else { return }
        importBoard(boardCandidates[index])
    }

    private func importBoard(_ boardURL: URL) {
        let doc = ownerDocument

        setBoardLoading(true)
        isLinking = true
        showEvent("Linking \(boardURL.lastPathComponent)…")
        projectPathField.isEnabled = false
        boardPopUp.isEnabled = false

        let config = doc.config
        let board = doc.board(at: boardURL.path)
        // Just a stackup query against boardURL directly (see KicadBoardBridge.link(toConfig:)'s doc
        // comment) -- no kicad-cli export, no copy into the document, so this doesn't touch the
        // filesystem at all and works whether or not the document has ever been saved. Still a
        // parsing work, so it remains off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try board.link(toConfig: config)
                // Fetched here (already off the main thread) rather than in importSucceeded, so the
                // ground-net guess below has real data to work with instead of a second async hop.
                let nets = (try? board.allNets()) ?? []
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
        isLinking = false
        projectPathField.isEnabled = true
        boardPopUp.isEnabled = true
        // The board pop-up already names the linked board.
        showEvent("")
        document.updateChangeCount(.changeDone)
        propertiesViewController?.refreshNetLists()
        sourceListViewController?.refreshBoardData()
        if wholeBoardViewController?.refresh() != true {
            // Relinking the already-loaded board does not start another preview request, so there
            // will be no loading callback to clear the link-stage overlay in that case.
            setBoardLoading(false)
        }
        simulationListViewController?.setProjectAvailable(true)

        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: boardURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        kicadFileWatcher.startWatching(pcbPath: boardURL.path, projectPath: Self.siblingProjectURL(among: siblings)?.path)

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
        // The ground guess goes into Board Setup (unless one is already chosen there), which every
        // new simulation, including this one, starts from.
        let boardSetup = document.config.boardSetup
        if boardSetup.groundNetName == nil, let groundNetGuess = GroundNetHeuristic.bestGuess(among: availableNets) {
            boardSetup.groundNetKind = .net
            boardSetup.groundNetName = groundNetGuess
        }
        _ = document.config.addSimulationNamed(simulationName)
        wholeBoardViewController?.applyBoardInclusions(toSimulationAt: document.config.simulations.count - 1)
        simulationListViewController?.simulationAddedExternally(at: document.config.simulations.count - 1)
    }

    private func importFailed(error: Error) {
        setBoardLoading(false)
        isLinking = false
        projectPathField.isEnabled = true
        boardPopUp.isEnabled = true
        showEvent("Link failed: \(error.localizedDescription)")
        NSApp.presentError(error)
    }

    private static func siblingProjectURL(among siblings: [URL]) -> URL? {
        siblings.first { $0.pathExtension == "kicad_pro" }
    }

    /// Called whenever KicadFileWatcher notices the linked board (or its sibling project file) has
    /// changed on disk -- typically the user saving in KiCad while this document is open. Nothing is
    /// reloaded here: every simulation is just marked out of date (yellow row and banner), keeping
    /// what was already computed on screen. The board-derived views (whole board, net/footprint
    /// pickers) catch up once geometry is next regenerated -- see applyPendingBoardReload().
    private func handleLinkedKicadFilesChanged() {
        guard ownerDocument.config.kicadPcbPath != nil else { return }
        hasPendingBoardReload = true
        for index in ownerDocument.config.simulations.indices {
            // See onInvolvedNetsChanged's identical comment on why all 3 rows.
            invalidate(simulationIndex: index, reason: "Board changed in KiCad", includingGeometry: true)
        }
    }

    /// Reloads the board-derived views deferred by handleLinkedKicadFilesChanged(), once the user
    /// asks for geometry to be regenerated from the changed board.
    private func applyPendingBoardReload() {
        guard hasPendingBoardReload else { return }
        hasPendingBoardReload = false
        propertiesViewController?.refreshNetLists()
        sourceListViewController?.refreshBoardData()
        wholeBoardViewController?.invalidate()
        wholeBoardViewController?.refresh()
    }

    /// Invalidates `index`'s cached results (and, if `includingGeometry`, its geometry) after an
    /// edit described by `reason`. Whatever was already computed stays visible as out of date (a
    /// yellow row and banner) until re-run; a nil `reason` discards it outright instead.
    private func invalidate(simulationIndex index: Int, reason: String?, includingGeometry: Bool) {
        // Results first: invalidating geometry drops the pipeline's results along with it, so the
        // results VC has to keep its out-of-date copy before that happens.
        simulationResultsViewController?.invalidateCache(forSimulationIndex: index, reason: reason)
        if includingGeometry {
            geometryViewController?.invalidateCache(forSimulationIndex: index, reason: reason)
            resetRow(forSimulationIndex: index, kind: .geometryGeneration)
        }
        resetRow(forSimulationIndex: index, kind: .simulation)
        resetRow(forSimulationIndex: index, kind: .fieldPostProcessing)
    }

    private func isSimulationSetTemplate(at index: Int) -> Bool {
        let simulations = ownerDocument.config.simulations
        return simulations.indices.contains(index) && simulations[index].simulationSet != nil
    }

    /// Rewrites the simulations generated from the Simulation Set template at `templateIndex` after
    /// an edit to it (see WholeBoardViewController.regenerateSimulationSet(atTemplateIndex:)), and
    /// invalidates every one that changed as invalidate(simulationIndex:reason:includingGeometry:)
    /// does for `reason`.
    private func regenerateSimulationSet(atTemplateIndex templateIndex: Int, reason: String?) {
        guard let regeneration = wholeBoardViewController?.regenerateSimulationSet(atTemplateIndex: templateIndex)
        else { return }
        let count = ownerDocument.config.simulations.count
        for index in regeneration.changedIndices where index < (regeneration.firstRemovedIndex ?? count) {
            invalidate(simulationIndex: index, reason: reason, includingGeometry: true)
        }
        // Removal shifts every later simulation down, so those positions' caches belong to other
        // simulations now and can't even be kept as out of date.
        if let first = regeneration.firstRemovedIndex {
            for index in first..<count {
                invalidate(simulationIndex: index, reason: nil, includingGeometry: true)
            }
        }
        simulationListViewController?.simulationSetRegenerated(at: templateIndex)
    }

    /// A Simulation Set template's analysis-only settings -- its Tests section, adversarial draws and
    /// shared clock, and excitation duration -- are copied to the simulations it generated, whose
    /// results are re-analysed in place rather than regenerated, which would discard them.
    private func simulationSetAnalysisChanged(atTemplateIndex templateIndex: Int) {
        let simulations = ownerDocument.config.simulations
        guard simulations.indices.contains(templateIndex), let set = simulations[templateIndex].simulationSet
        else { return }
        ownerDocument.updateChangeCount(.changeDone)
        for (index, simulation) in simulations.enumerated() where simulation.generatedBySetIdentifier == set.identifier {
            simulation.copyEyeAnalysisSettings(from: simulations[templateIndex])
            if let duration = set.excitationDuration?.doubleValue {
                for excitation in simulation.excitations where excitation.isMain {
                    excitation.duration = duration
                }
            }
            simulationResultsViewController?.eyeSettingsChanged(forSimulationIndex: index)
            refreshEyeTestStatus(forSimulationIndex: index)
        }
    }

    /// Re-checks `index`'s results against its eye mask, for the sidebar's stop sign on its
    /// Simulation Results row. Results that don't exist (yet) don't fail.
    private func refreshEyeTestStatus(forSimulationIndex index: Int) {
        let failed = simulationResultsViewController?.eyeTestFails(forSimulationIndex: index) ?? false
        simulationListViewController?.setTestsFailed(failed, forSimulationIndex: index)
    }

    /// Puts `kind`'s sidebar row back to whatever its view controller has left to show once nothing
    /// current is cached: out of date (yellow) if it kept a previous result, otherwise not run.
    private func resetRow(forSimulationIndex index: Int, kind: JobKind) {
        let hasStale: Bool
        switch kind {
        case .geometryGeneration:
            hasStale = geometryViewController?.hasStaleGeometry(forSimulationIndex: index) ?? false
        case .simulation:
            hasStale = simulationResultsViewController?.hasStaleResults(forSimulationIndex: index) ?? false
        case .fieldPostProcessing:
            hasStale = false
        }
        if hasStale {
            simulationListViewController?.setOutOfDate(forSimulationIndex: index, kind: kind)
        } else {
            simulationListViewController?.setInvalid(forSimulationIndex: index, kind: kind)
        }
    }

    /// File > Regenerate Geometry -- force-discards every cached pipeline stage (board slicing,
    /// stackup import, port/lumped-component resolution, grid, results) for every simulation in
    /// this document, so the next Geometry/Results run recomputes everything from scratch instead
    /// of reusing anything already resolved in memory. Unlike handleLinkedKicadFilesChanged() above
    /// (which only fires when KicadFileWatcher notices the linked .kicad_pcb itself changed on
    /// disk), this exists for the case nothing on disk changed but the *interpretation* of it did --
    /// e.g. a fix to how libkicad resolves nets/footprints/pins --
    /// which no automatic cache invalidation elsewhere in this app is designed to detect, since
    /// EMSSimulationPipelineBridge's own ensurePrepared: only ever re-derives _paths (and therefore
    /// re-runs exportKicadPcb/importStackup/resolveSimulationPorts) once per pipeline instance's
    /// whole lifetime otherwise (see that method's own doc comment).
    @objc func regenerateGeometry(_ sender: Any?) {
        for index in ownerDocument.config.simulations.indices {
            invalidate(simulationIndex: index, reason: nil, includingGeometry: true)
            fieldViewerViewController?.invalidateCache(forSimulationIndex: index)
        }
    }

    /// File > Reset Results -- like regenerateGeometry(_:) but discards only the simulation results
    /// (FDTD run and its field post-processing) for every simulation, keeping the resolved geometry.
    @objc func resetResults(_ sender: Any?) {
        for index in ownerDocument.config.simulations.indices {
            invalidate(simulationIndex: index, reason: nil, includingGeometry: false)
            fieldViewerViewController?.invalidateCache(forSimulationIndex: index)
        }
    }

    /// File > Rerun Postprocessing -- recomputes S-parameters/impedance/eye data for every
    /// simulation from its existing FDTD run, without re-running FDTD or touching geometry/fields.
    @objc func rerunPostprocessing(_ sender: Any?) {
        for index in ownerDocument.config.simulations.indices {
            simulationResultsViewController?.rerunPostprocessing(forSimulationIndex: index)
        }
    }

    /// The sidebar's status dots otherwise only come from runs in this session. Marks whatever the
    /// package's completion.json says had finished, where its fingerprint still matches the
    /// document and board, and has every save record the sidebar's state back into it.
    private func restoreSavedStatuses() {
        ownerDocument.currentCompletions = { [weak self] in
            guard let self, let list = self.simulationListViewController else { return [:] }
            var completions: [String: (geometry: Bool, results: Bool, testsFailed: Bool)] = [:]
            for (index, simulation) in self.ownerDocument.config.simulations.enumerated() {
                completions[simulation.name] = (
                    geometry: list.phaseState(forSimulationIndex: index, kind: .geometryGeneration) == .succeeded,
                    results: list.phaseState(forSimulationIndex: index, kind: .simulation) == .succeeded,
                    testsFailed: list.testsFailed(forSimulationIndex: index))
            }
            return completions
        }
        guard ownerDocument.hasCompletionRecord else { return migrateCompletionRecord() }
        let saved = ownerDocument.savedCompletions
        guard !saved.isEmpty, let list = simulationListViewController else { return }
        let fingerprints = ownerDocument.config.completionFingerprints()
        for (index, simulation) in ownerDocument.config.simulations.enumerated() {
            guard let completion = saved[simulation.name], completion.fingerprint == fingerprints[simulation.name]
            else { continue }
            if completion.geometry {
                list.setCompleted(true, forSimulationIndex: index, kind: .geometryGeneration)
            }
            if completion.results {
                list.setCompleted(true, forSimulationIndex: index, kind: .simulation)
                list.setCompleted(true, forSimulationIndex: index, kind: .fieldPostProcessing)
                list.setTestsFailed(completion.testsFailed, forSimulationIndex: index)
            }
        }
    }

    /// File > Save Report… -- writes a PDF summarising every simulation's test verdict, followed by
    /// each one's eye diagrams and other result charts (see ResultsReport).
    @objc func saveReport(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(ownerDocument.displayName ?? "KiEMS") Report.pdf"
        let optionsView = ReportOptionsAccessoryView(options: .saved)
        panel.accessoryView = optionsView
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let options = optionsView.options
            ReportOptions.saved = options
            // One simulation at a time: restore it, take what the report needs, then let it go, so
            // the export never holds every simulation's board, geometry and results at once.
            var entries: [Int: ResultsReport.Entry] = [:]
            self.restoreSavedResults(releasingEach: true, onRestored: { [weak self] name in
                guard let self, let resultsVC = self.simulationResultsViewController,
                      let index = self.ownerDocument.config.simulations.firstIndex(where: { $0.name == name })
                else { return }
                self.markRestoredStages(forSimulationNamed: name)
                entries[index] = self.reportEntry(forSimulationIndex: index, resultsVC: resultsVC,
                                                  options: options)
            }) {
                do {
                    try self.writeReport(to: url, options: options, restoredEntries: entries)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    /// Loads every simulation's saved results that are still valid for its current configuration,
    /// so the report judges them rather than calling them not run -- they otherwise only load when
    /// the simulation's job next runs. Skips simulations with results already loaded or a job queued
    /// or running (whatever that job produces is what counts). Calls `completion` on the main thread.
    /// A package saved before completion.json existed: restore its saved stages in the background
    /// the slow way, marking each simulation as it comes back, then record the result so the next
    /// open is instant.
    private func migrateCompletionRecord() {
        guard ownerDocument.packageURL != nil else { return }
        restoreSavedResults(showingProgress: false, onRestored: { [weak self] name in
            self?.markRestoredStages(forSimulationNamed: name)
        }, completion: { [weak self] in
            self?.ownerDocument.recordCompletions()
        })
    }

    private func markRestoredStages(forSimulationNamed name: String) {
        guard let list = simulationListViewController,
              let index = ownerDocument.config.simulations.firstIndex(where: { $0.name == name }) else { return }
        let pipeline = ownerDocument.pipeline(forSimulationNamed: name)
        // A phase that's queued, running or already reported keeps what it shows.
        if pipeline.hasStage(.grid), list.phaseState(forSimulationIndex: index, kind: .geometryGeneration) == .invalid {
            list.setCompleted(true, forSimulationIndex: index, kind: .geometryGeneration)
        }
        guard pipeline.hasStage(.results) else {
            // completion.json said this had finished, but its saved results don't fit the current
            // model (e.g. its ports now resolve differently): stop showing it as done.
            if restoreErrors[name] != nil || pipeline.savedResultsUnavailableReason() != nil,
               list.phaseState(forSimulationIndex: index, kind: .simulation) == .succeeded,
               !JobKind.allCases.contains(where: {
                   JobScheduler.shared.job(document: ownerDocument, simulationName: name, kind: $0) != nil
               }) {
                resetRow(forSimulationIndex: index, kind: .simulation)
                resetRow(forSimulationIndex: index, kind: .fieldPostProcessing)
            }
            return
        }
        for kind in [JobKind.simulation, .fieldPostProcessing]
        where list.phaseState(forSimulationIndex: index, kind: kind) == .invalid {
            list.setCompleted(true, forSimulationIndex: index, kind: kind)
        }
        refreshEyeTestStatus(forSimulationIndex: index)
    }

    /// Calls `onRestored` on the main thread with each simulation's name as its restore finishes.
    /// With `releasingEach`, each simulation it restored is unloaded again once `onRestored` has
    /// returned (unless a job has since claimed it), keeping only one in memory at a time.
    func restoreSavedResults(showingProgress: Bool = true, releasingEach: Bool = false,
                             onRestored: @escaping (String) -> Void = { _ in },
                             completion: @escaping () -> Void) {
        let scheduler = JobScheduler.shared
        let packageDir = ownerDocument.pipelineDirectory
        let pipelines = ownerDocument.config.simulations.compactMap { simulation -> (name: String, pipeline: EMSSimulationPipelineBridge)? in
            guard simulation.simulationSet == nil else { return nil }
            // Without a geometry or results cache-input stamp there's nothing restorable, so skip
            // the board export and port resolution a restore costs (seconds per simulation).
            let hasStamp = ["ems/geometry", "ems/simulation"].contains { stage in
                FileManager.default.fileExists(atPath: packageDir.appendingPathComponent(stage, isDirectory: true)
                    .appendingPathComponent(simulation.name, isDirectory: true)
                    .appendingPathComponent("cache_inputs.txt").path)
            }
            guard hasStamp else { return nil }
            let pipeline = ownerDocument.pipeline(forSimulationNamed: simulation.name)
            let hasJob = JobKind.allCases.contains {
                scheduler.job(document: ownerDocument, simulationName: simulation.name, kind: $0) != nil
            }
            return pipeline.hasStage(.results) || hasJob ? nil : (simulation.name, pipeline)
        }
        guard !pipelines.isEmpty else { return completion() }
        let config = ownerDocument.config
        let kicadCliPath = AppPaths.resolveKicadCli()
        // The report covers every simulation, so count those already loaded as done.
        let reportable = ownerDocument.config.simulations.filter { $0.simulationSet == nil }.count
        let alreadyLoaded = max(0, reportable - pipelines.count)
        let progressSheet = showingProgress
            ? ReportProgressSheet(total: alreadyLoaded + pipelines.count, alreadyCompleted: alreadyLoaded) : nil
        if let progressSheet {
            window?.beginSheet(progressSheet.window)
        }
        restoreQueue.async {
            for (index, (name, pipeline)) in pipelines.enumerated() {
                DispatchQueue.main.async { progressSheet?.show(completed: alreadyLoaded + index) }
                // A failure (no board, an export error) leaves that simulation without results; the
                // report says why rather than calling it not run.
                var restoreError: String?
                do {
                    try pipeline.restoreSavedStages(withConfig: config, packageDir: packageDir.path,
                                                    kicadCliPath: kicadCliPath)
                } catch {
                    restoreError = error.localizedDescription
                    NSLog("[restore] %@: %@", name, error.localizedDescription)
                }
                // Synchronously, so a released simulation's results are read before they go.
                let release = DispatchQueue.main.sync { [weak self] () -> Bool in
                    guard let self else { return false }
                    self.restoreErrors[name] = restoreError
                    onRestored(name)
                    return releasingEach && !JobKind.allCases.contains {
                        scheduler.job(document: self.ownerDocument, simulationName: name, kind: $0) != nil
                    }
                }
                if release {
                    pipeline.releaseLoadedStages()
                }
            }
            DispatchQueue.main.async { [weak self] in
                progressSheet?.show(completed: alreadyLoaded + pipelines.count)
                // Writing happens in completion, so the sheet stays up until it's done.
                completion()
                if let progressSheet {
                    self?.window?.endSheet(progressSheet.window)
                }
            }
        }
    }

    /// `restoredEntries` are entries already taken from simulations loaded only for this report;
    /// every other simulation's is built from what it has loaded now.
    func writeReport(to url: URL, options: ReportOptions = ReportOptions(),
                     restoredEntries: [Int: ResultsReport.Entry] = [:]) throws {
        guard let resultsVC = simulationResultsViewController else { return }
        // A Simulation Set only generates simulations; those are the tests. On the summary page
        // they're gathered under their set, in its place, rather than listed one by one.
        let simulations = ownerDocument.config.simulations
        var entries = restoredEntries
        for index in simulations.indices where simulations[index].simulationSet == nil && entries[index] == nil {
            entries[index] = reportEntry(forSimulationIndex: index, resultsVC: resultsVC, options: options)
        }
        let setIdentifiers = Set(simulations.compactMap { $0.simulationSet?.identifier })
        let summary = simulations.indices.compactMap { index -> ResultsReport.SummaryItem? in
            let simulation = simulations[index]
            if let set = simulation.simulationSet {
                let members = simulations.indices
                    .filter { simulations[$0].generatedBySetIdentifier == set.identifier }
                    .compactMap { member in entries[member].map { (name: $0.name, verdict: $0.verdict) } }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return .set(name: simulation.name, members: members)
            }
            if let generatedBy = simulation.generatedBySetIdentifier, setIdentifiers.contains(generatedBy) {
                return nil
            }
            return entries[index].map { .simulation($0) }
        }
        try ResultsReport.pdfData(title: ownerDocument.displayName ?? "KiEMS", summary: summary,
                                  entries: entries.keys.sorted().compactMap { entries[$0] },
                                  includeTestResults: options.includeTestResults)
            .write(to: url, options: .atomic)
    }

    private func reportEntry(forSimulationIndex index: Int,
                             resultsVC: SimulationResultsViewController,
                             options: ReportOptions) -> ResultsReport.Entry {
        let simulation = ownerDocument.config.simulations[index]
        let pipeline = ownerDocument.pipeline(forSimulationNamed: simulation.name)
        let results = resultsVC.reportResults(forSimulationIndex: index)
        var pipelineWarnings: [String] = []
        if let shorts = pipeline.metalShortsWarning() {
            pipelineWarnings += shorts.components(separatedBy: "\n")
        }
        if let kicad = pipeline.kicadSourcesWarning() {
            pipelineWarnings.append(kicad)
        }
        // TEMPORARY: renumbered results pass without their warning while the HorizonPC reruns are
        // pending. Restore this before committing.
        // if let renumbered = pipeline.renumberedResultsWarning() {
        //     pipelineWarnings.append(renumbered)
        // }
        var (verdict, notes) = ResultsReport.verdict(preview: results?.preview,
                                                     runError: resultsVC.runError(forSimulationIndex: index),
                                                     staleReasons: results?.staleReasons ?? [],
                                                     pipelineWarnings: results == nil ? [] : pipelineWarnings)
        if verdict == .notRun, let reason = restoreErrors[simulation.name] ?? pipeline.savedResultsUnavailableReason() {
            notes.append("Saved results couldn't be restored: \(reason)")
        }
        // Eye diagrams first: they're what the verdict is about.
        let categories: [(title: String, sections: [ResultsSection])] = results.map { results in
            let all = SimulationResultsViewController.categories(for: results.preview)
                .filter(options.categories.contains)
            let ordered = all.filter { $0 == .eyeDiagrams } + all.filter { $0 != .eyeDiagrams }
            return ordered.map { category -> (title: String, sections: [ResultsSection]) in
                (title: category.title,
                 sections: resultsVC.sections(for: category, preview: results.preview, forReport: true))
            }
        } ?? []
        let setName = simulation.generatedBySetIdentifier.flatMap { identifier in
            ownerDocument.config.simulations.first { $0.simulationSet?.identifier == identifier }?.name
        }
        return ResultsReport.Entry(name: simulation.name, setName: setName, verdict: verdict, notes: notes,
                                   categories: categories)
    }

    private static func titleCased(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    // MARK: - Toolbar

    /// Run: the selected simulation, or every simulation a selected Simulation Set generated.
    @objc private func runSelectedSimulations(_ sender: Any?) {
        run(simulationListViewController?.selectedRunTargets ?? [])
    }

    @objc private func runAllSimulations(_ sender: Any?) {
        run(simulationListViewController?.allRunTargets ?? [])
    }

    /// Queues each of `indices` whose results aren't already current or queued. JobScheduler runs
    /// the most recent request first, so they're requested last first to run in list order.
    private func run(_ indices: [Int]) {
        guard let list = simulationListViewController else { return }
        for index in indices.reversed() where list.canRun(simulationIndex: index) {
            simulationResultsViewController?.runSimulation(forSimulationIndex: index)
        }
    }

    /// Pauses or resumes the job queue -- app-wide, like the queue itself (see JobScheduler.setPaused).
    @objc private func togglePause(_ sender: Any?) {
        JobScheduler.shared.setPaused(!JobScheduler.shared.isPaused)
    }

    /// Enables Run/Run All only while they'd queue something, and Pause while this document has jobs
    /// to pause (or the queue is already paused, to resume it). Called on every selection, row status
    /// and scheduler change.
    private func updateToolbarItems() {
        let list = simulationListViewController
        let isReady = ownerDocument.config.kicadPcbPath != nil && !isLoadingBoard
        let canRunAny = { (indices: [Int]) in
            isReady && indices.contains { list?.canRun(simulationIndex: $0) ?? false }
        }
        runItem?.isEnabled = canRunAny(list?.selectedRunTargets ?? [])
        runAllItem?.isEnabled = canRunAny(list?.allRunTargets ?? [])

        let scheduler = JobScheduler.shared
        let hasActiveJobs = scheduler.jobs.contains { job in
            guard job.document === ownerDocument else { return false }
            if case .failed = job.status { return false }
            return true
        }
        guard let pauseItem else { return }
        pauseItem.isEnabled = scheduler.isPaused || hasActiveJobs
        let isPaused = scheduler.isPaused
        guard (pauseItem.style == .prominent) != isPaused else { return }
        // Paused, the button stays lit until it's pressed again to resume.
        pauseItem.style = isPaused ? .prominent : .plain
        pauseItem.backgroundTintColor = isPaused ? .systemOrange : nil
        pauseItem.label = isPaused ? "Resume" : "Pause"
        pauseItem.toolTip = isPaused ? "Resume running simulations" : "Pause running simulations"
    }

    private func makeButtonItem(_ identifier: NSToolbarItem.Identifier, label: String, symbolName: String,
                                toolTip: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        // Enabled explicitly by updateToolbarItems() as the selection and job states change.
        item.autovalidates = false
        item.isEnabled = false
        return item
    }

    // MARK: - Status display

    /// The status display fits in the toolbar beside the sidebar, so it tracks the sidebar's width.
    @objc private func sidebarDidResize(_ notification: Notification?) {
        guard let sidebar = splitViewController.splitViewItems.first?.viewController.view else { return }
        statusView.leadingToolbarWidth = sidebar.frame.width
        if let window { statusView.updateWidth(forWindowWidth: window.frame.width) }
    }

    private static let eventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// Sets the message the status display shows once nothing of this document's is running.
    private func showEvent(_ message: String) {
        lastEventMessage = message
        refreshStatusDisplay()
    }

    /// Like Xcode's "Build Succeeded | Today at 10:42", for a finished simulation run.
    private func showRunOutcome(forSimulationIndex index: Int, success: Bool) {
        guard ownerDocument.config.simulations.indices.contains(index) else { return }
        let name = ownerDocument.config.simulations[index].name
        let outcome = success ? "Simulated “\(name)”" : "Simulating “\(name)” failed"
        showEvent("\(outcome) | \(Self.eventTimeFormatter.string(from: Date()))")
    }

    /// The status display's activity: a board link in progress; otherwise this document's running
    /// job and how many of its simulations are queued behind it (or that the queue is paused, or
    /// waiting on another document's job); otherwise the outcome of the last link or run.
    private func refreshStatusDisplay() {
        if isLinking {
            statusView.setActivity(lastEventMessage, isBusy: true, fraction: nil)
            return
        }
        let scheduler = JobScheduler.shared
        let ownJobs = scheduler.jobs.filter { $0.document === ownerDocument }
        let current = ownJobs.first { $0.status == .running || $0.status == .cancelling }
        var queuedSimulations = Set(ownJobs.filter { $0.status == .queued }.map(\.simulationName))
        if let current { queuedSimulations.remove(current.simulationName) }
        let queuedCount = queuedSimulations.count
        let queued = queuedCount == 0 ? nil
            : "\(queuedCount) \(current == nil ? "" : "more ")simulation\(queuedCount == 1 ? "" : "s") queued"

        guard let current else {
            if let queued {
                let reason = scheduler.isPaused ? "Paused" : "Waiting for another document"
                statusView.setActivity("\(reason) · \(queued)", isBusy: false, fraction: nil)
            } else {
                statusView.setActivity(lastEventMessage, isBusy: false, fraction: nil)
            }
            return
        }
        let description = "\(current.kind.progressVerbPhrase) “\(current.simulationName)”"
        var parts: [String]
        var isBusy = false
        var fraction: Double?
        if current.status == .cancelling {
            parts = ["Cancelling: \(description)"]
            isBusy = true
        } else if scheduler.isPaused {
            // Held runs keep their progress line, frozen where they stopped.
            parts = [scheduler.isHoldingRunningJob ? "Paused: \(description)" : "Pausing: \(description)…"]
            fraction = current.progress?.phase == .settingUp ? nil : current.progress?.fraction
        } else {
            let info = current.progressStatusInfo
            fraction = info?.fraction
            parts = [description]
            if let fraction { parts[0] += " — \(Int((fraction * 100).rounded()))%" }
            if let estimate = info?.timeEstimateText { parts.append(estimate) }
            isBusy = true
        }
        if let queued { parts.append(queued) }
        statusView.setActivity(parts.joined(separator: " · "), isBusy: isBusy, fraction: fraction)
    }

    /// The source-list rows showing each failed eye test (errors) and each warning, in list order --
    /// what the status display counts, and steps through when a count is clicked. Warnings are what
    /// the source list and banners flag in yellow: failed or out-of-date steps, and current results
    /// carrying a warning (unsaved KiCad changes used, grid shorts between nets).
    private func currentIssues() -> (errors: [SimulationListSelection], warnings: [SimulationListSelection]) {
        guard let list = simulationListViewController else { return ([], []) }
        let simulations = ownerDocument.config.simulations
        var errors: [SimulationListSelection] = []
        var warnings: [SimulationListSelection] = []
        for index in list.allRunTargets where simulations.indices.contains(index) {
            let geometry = list.phaseState(forSimulationIndex: index, kind: .geometryGeneration)
            let results = list.phaseState(forSimulationIndex: index, kind: .simulation)
            let fields = list.phaseState(forSimulationIndex: index, kind: .fieldPostProcessing)
            if list.showsFailedTests(forSimulationIndex: index) {
                errors.append(.simulationResults(simulationIndex: index))
            }
            if geometry == .failed || geometry == .outOfDate {
                warnings.append(.geometry(simulationIndex: index))
            }
            if results == .failed || results == .outOfDate {
                warnings.append(.simulationResults(simulationIndex: index))
            }
            if fields == .failed {
                warnings.append(.fieldViewer(simulationIndex: index))
            }
            // Only a simulation with something current has pipeline warnings to report -- and its
            // pipeline is then idle, so safe to ask.
            guard geometry == .succeeded || results == .succeeded else { continue }
            let pipeline = ownerDocument.pipeline(forSimulationNamed: simulations[index].name)
            if pipeline.kicadSourcesWarning() != nil {
                warnings.append(results == .succeeded ? .simulationResults(simulationIndex: index)
                                                      : .geometry(simulationIndex: index))
            }
            if results == .succeeded, pipeline.metalShortsWarning() != nil {
                warnings.append(.simulationResults(simulationIndex: index))
            }
        }
        return (errors, warnings)
    }

    private func refreshIssueCounts() {
        let issues = currentIssues()
        statusView.setIssueCounts(errors: issues.errors.count, warnings: issues.warnings.count)
    }

    /// Selects the row of the next failed test (or warning) after the selected one, wrapping round,
    /// so clicking a count repeatedly steps through them all.
    private func showNextIssue(errors: Bool) {
        let issues = currentIssues()
        // One row can carry more than one warning; each row is a single stop.
        let rows = (errors ? issues.errors : issues.warnings).reduce(into: [SimulationListSelection]()) { rows, row in
            if !rows.contains(row) { rows.append(row) }
        }
        guard !rows.isEmpty else { return }
        let next = currentSelection.flatMap { rows.firstIndex(of: $0) }.map { ($0 + 1) % rows.count } ?? 0
        simulationListViewController?.select(rows[next])
    }
}

private extension NSToolbarItem.Identifier {
    static let runSimulation = NSToolbarItem.Identifier("KiEMS.runSimulation")
    static let runAllSimulations = NSToolbarItem.Identifier("KiEMS.runAllSimulations")
    static let pauseSimulations = NSToolbarItem.Identifier("KiEMS.pauseSimulations")
    static let statusDisplay = NSToolbarItem.Identifier("KiEMS.statusDisplay")
}

extension DocumentWindowController: NSToolbarDelegate {
    // Items before the tracking separator sit on the sidebar; it follows the sidebar's width.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.runSimulation, .runAllSimulations, .pauseSimulations, .sidebarTrackingSeparator, .statusDisplay]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .runSimulation:
            let item = makeButtonItem(itemIdentifier, label: "Run", symbolName: "play.fill",
                                      toolTip: "Run the selected simulation, or every simulation in the selected set",
                                      action: #selector(runSelectedSimulations(_:)))
            runItem = item
            return item
        case .runAllSimulations:
            let item = makeButtonItem(itemIdentifier, label: "Run All", symbolName: "forward.fill",
                                      toolTip: "Run every simulation", action: #selector(runAllSimulations(_:)))
            runAllItem = item
            return item
        case .pauseSimulations:
            let item = makeButtonItem(itemIdentifier, label: "Pause", symbolName: "pause.fill",
                                      toolTip: "Pause running simulations", action: #selector(togglePause(_:)))
            pauseItem = item
            return item
        case .statusDisplay:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Status"
            item.view = statusView
            // The display draws its own glass capsule.
            item.isBordered = false
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }
}

extension DocumentWindowController: NSWindowDelegate {
    /// Resizes the status display before the toolbar lays out at the new width -- sized afterwards,
    /// a shrinking window found it still too wide and pushed every item into the overflow menu.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        statusView.updateWidth(forWindowWidth: frameSize.width)
        return frameSize
    }
}

/// Save Report's sheet while saved results load and the report is written -- see DocumentWindowController.restoreSavedResults.
private final class ReportProgressSheet {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90),
                          styleMask: [.titled], backing: .buffered, defer: true)
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let total: Int

    init(total: Int, alreadyCompleted: Int = 0) {
        self.total = total
        bar.style = .bar
        bar.controlSize = .regular
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = Double(total)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        window.contentView = stack
        show(completed: alreadyCompleted)
    }

    func show(completed: Int) {
        label.stringValue = "Writing Simulation Report (\(min(completed + 1, total)) of \(total))…"
        bar.doubleValue = Double(completed)
    }
}
