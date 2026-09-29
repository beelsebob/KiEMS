import Cocoa

/// Custom view for one Field-series popup item. NSMenuItem keeps its ordinary title for popup
/// selection/accessibility; this view only replaces the menu row's drawing so excitation names use
/// the same KiCad-aware formatting as net names everywhere else in the app.
private final class FieldSeriesMenuItemView: NSView {
    private let nameCell = NetNameCellView()

    init(title: String) {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let textSize = NetNameFormatting.size(for: NetNameFormatting.segments(for: title, font: font))
        let horizontalInset: CGFloat = 14
        let rowHeight = max(22, ceil(textSize.height) + 6)
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: max(300, ceil(textSize.width) + horizontalInset * 2),
                                 height: rowHeight))

        nameCell.configure(name: title, font: font)
        nameCell.frame = bounds.insetBy(dx: horizontalInset, dy: 0)
        nameCell.autoresizingMask = [.width, .height]
        addSubview(nameCell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillDraw() {
        nameCell.backgroundStyle = enclosingMenuItem?.isHighlighted == true ? .emphasized : .normal
        super.viewWillDraw()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // NetNameCellView is visual content here, not a separate control. Keep it from becoming the
        // deepest hit view so clicks reach this menu-row view's mouseUp implementation below.
        super.hitTest(point) == nil ? nil : self
    }

    /// Once an NSMenuItem has a custom view AppKit leaves pointer handling to that view, so the
    /// popup button no longer performs the item automatically. Route a completed click back through
    /// NSMenu's normal action machinery to preserve target/action and accessibility behaviour.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)),
              let item = enclosingMenuItem,
              let menu = item.menu,
              let itemIndex = menu.items.firstIndex(of: item) else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: itemIndex)
    }
}

/// Content for a simulation's "Field Viewer" sub-entry, selected via SimulationListViewController's
/// outline view. Shares the same `.results` pipeline stage SimulationResultsViewController drives
/// (a real FDTD run) -- selecting this tab for a simulation whose results aren't cached yet kicks
/// off that same run, exactly as selecting "Simulation Results" would; whichever tab is visited
/// first pays for it, the other reuses the cached result (see EMSSimulationPipelineBridge's own doc
/// comment on stage sharing). Renders the result with FieldView once available.
final class FieldViewerViewController: NSViewController {
    private weak var document: Document?

    private let fieldView = FieldView()
    private let progressStatus = ProgressStatusView()

    // MARK: - Simulation/excitation selection

    private let seriesSelectorBackground = NSVisualEffectView()
    private let seriesPopUp = NSPopUpButton()
    private let seriesProgressIndicator = NSProgressIndicator()
    private let seriesProgressPrefix = NSTextField(labelWithString: "")
    private let seriesProgressNetName = NetNameView()
    private var seriesProgressStack: NSStackView!
    private var currentSnapshots: [EMSFieldSnapshot] = []
    private var selectedExcitedPortBySimulation: [Int: Int] = [:]
    private var displayedSeriesKey: String?

    // MARK: - Playback transport (video-player-style controls over fieldSnapshot.frames)

    private let transportBackground = NSVisualEffectView()
    private let playPauseButton = NSButton()
    private let frameSlider = NSSlider()
    private let frameLabel = NSTextField(labelWithString: "")
    private var playbackTimer: Timer?
    private var isPlaying = false
    /// The currently-displayed snapshot's own frames -- cached here (rather than re-reading
    /// `fieldView.fieldSnapshot?.frames` on every timer tick) purely so advanceFrame()/updateFrameLabel()
    /// have a cheap, obviously-non-optional source for frame count and each frame's own timeSeconds.
    private var currentFrames: [EMSFieldFrame] = []
    /// Fixed playback rate -- see startPlayback()'s own doc comment for why this isn't derived from
    /// each frame's own real (highly non-uniform) timeSeconds spacing.
    private static let playbackInterval: TimeInterval = 0.1

    private var errors: [Int: String] = [:]
    private var runningIndices: Set<Int> = []
    private var latestProgress: [Int: EMSPipelineProgress] = [:]
    private var runStartTime: [Int: Date] = [:]
    private var timeEstimateText: [Int: String] = [:]
    private var currentIndex: Int?
    /// DocumentWindowController swaps the right-hand panes by toggling their views' `isHidden`
    /// properties directly, so NSViewController appearance callbacks are not a dependable signal
    /// for whether this pane is selected. Scheduler notifications still need to update the cheap
    /// job/progress bookkeeping while hidden, but must not reopen field frames and rebuild the
    /// voxel colour buffer on every tick.
    private var isViewerVisible = false
    /// The JobKind actually driving `runningIndices`'/`latestProgress`'s own updates for each
    /// simulation, as of the most recent syncFromScheduler() tick -- see that method's own doc
    /// comment for why `activeJob` (and therefore its kind) can silently change mid-run as this
    /// simulation progresses through its prerequisite chain (geometry -> simulation ->
    /// field post-processing), with no corresponding onRunStateChanged transition to hang a "kind
    /// just changed" event off of. Captured here (rather than re-read from JobScheduler at the point
    /// a run finishes, when the job that was actually running may already have been removed) so
    /// onRunFinished/onRunCancelled can still report the right kind even after its own Job is gone.
    private var runningJobKind: [Int: JobKind] = [:]

    /// Fired whenever a given simulation's *currently active prerequisite* job starts/stops running
    /// -- `kind` is whichever of .geometryGeneration/.simulation/.fieldPostProcessing is actually
    /// driving it at that moment (see syncFromScheduler()'s own doc comment for why this VC has to
    /// watch all three, not just .fieldPostProcessing, for its own content-pane progress display).
    /// DocumentWindowController must filter on `kind == .fieldPostProcessing` before relaying to the
    /// sidebar's own Field Viewer row (see SimulationListViewController.setBusy/etc.) -- forwarding
    /// every kind unfiltered was the source of a real bug: a geometry-phase progress report making
    /// the Field Viewer row's own indicator fill up while geometry was still building.
    var onRunStateChanged: ((Int, JobKind, Bool) -> Void)?
    var onRunFinished: ((Int, JobKind, Bool) -> Void)?
    var onProgressChanged: ((Int, JobKind, EMSPipelineProgress) -> Void)?
    /// See GeometryViewController.onRunCancelled's identical doc comment, and onRunStateChanged's
    /// own doc comment above for why `kind` is required here too.
    var onRunCancelled: ((Int, JobKind) -> Void)?

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
        JobScheduler.shared.addChangeObserver { [weak self] in self?.syncFromScheduler() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopPlayback()
        fieldView.setRefinementEnabled(false)
        fieldView.discardCachedFrameData()
    }

    /// Called by DocumentWindowController after it has selected or hidden this pane. Becoming
    /// visible performs one catch-up refresh from the pipeline's latest snapshot; becoming hidden
    /// stops playback and drops decoded frame data immediately. Progress state continues to be
    /// tracked by syncFromScheduler() either way.
    func setViewerVisible(_ visible: Bool) {
        guard isViewerVisible != visible else { return }
        isViewerVisible = visible
        if visible {
            refreshDisplay()
            fieldView.setRefinementEnabled(true)
        } else {
            stopPlayback()
            fieldView.setRefinementEnabled(false)
            fieldView.discardCachedFrameData()
        }
    }

    override func loadView() {
        let container = NSView()

        fieldView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fieldView)

        progressStatus.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressStatus)

        NSLayoutConstraint.activate([
            fieldView.topAnchor.constraint(equalTo: container.topAnchor),
            fieldView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fieldView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fieldView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            progressStatus.topAnchor.constraint(equalTo: container.topAnchor),
            progressStatus.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressStatus.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressStatus.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        setUpTransport(in: container)
        setUpSeriesSelector(in: container)

        view = container
    }

    private func setUpSeriesSelector(in container: NSView) {
        seriesSelectorBackground.material = .hudWindow
        seriesSelectorBackground.blendingMode = .withinWindow
        seriesSelectorBackground.state = .active
        seriesSelectorBackground.wantsLayer = true
        seriesSelectorBackground.layer?.cornerRadius = 8
        seriesSelectorBackground.translatesAutoresizingMaskIntoConstraints = false
        seriesSelectorBackground.isHidden = true
        container.addSubview(seriesSelectorBackground)

        let label = NSTextField(labelWithString: "Field:")
        label.textColor = .labelColor

        seriesPopUp.target = self
        seriesPopUp.action = #selector(seriesSelectionChanged)

        seriesProgressIndicator.style = .spinning
        seriesProgressIndicator.controlSize = .small
        seriesProgressIndicator.startAnimation(nil)
        let progressFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        seriesProgressPrefix.font = progressFont
        seriesProgressPrefix.textColor = .secondaryLabelColor
        seriesProgressStack = NSStackView(views: [seriesProgressIndicator,
                                                   seriesProgressPrefix,
                                                   seriesProgressNetName])
        seriesProgressStack.orientation = .horizontal
        seriesProgressStack.alignment = .centerY
        seriesProgressStack.spacing = 3
        seriesProgressStack.isHidden = true

        let stack = NSStackView(views: [label, seriesPopUp, seriesProgressStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        seriesSelectorBackground.addSubview(stack)

        NSLayoutConstraint.activate([
            seriesSelectorBackground.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            seriesSelectorBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: seriesSelectorBackground.topAnchor),
            stack.leadingAnchor.constraint(equalTo: seriesSelectorBackground.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: seriesSelectorBackground.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: seriesSelectorBackground.bottomAnchor),
            seriesPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    private func setUpTransport(in container: NSView) {
        transportBackground.material = .hudWindow
        transportBackground.blendingMode = .withinWindow
        transportBackground.state = .active
        transportBackground.wantsLayer = true
        transportBackground.layer?.cornerRadius = 10
        transportBackground.translatesAutoresizingMaskIntoConstraints = false
        transportBackground.isHidden = true
        container.addSubview(transportBackground)

        playPauseButton.bezelStyle = .texturedRounded
        playPauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playPauseButton.imagePosition = .imageOnly
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayback)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false

        frameSlider.minValue = 0
        frameSlider.maxValue = 0
        frameSlider.isContinuous = true
        frameSlider.target = self
        frameSlider.action = #selector(sliderChanged)
        frameSlider.translatesAutoresizingMaskIntoConstraints = false

        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        frameLabel.textColor = .labelColor
        frameLabel.alignment = .right
        frameLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [playPauseButton, frameSlider, frameLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        transportBackground.addSubview(stack)

        NSLayoutConstraint.activate([
            transportBackground.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            transportBackground.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            transportBackground.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            stack.topAnchor.constraint(equalTo: transportBackground.topAnchor),
            stack.leadingAnchor.constraint(equalTo: transportBackground.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: transportBackground.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: transportBackground.bottomAnchor),

            frameLabel.widthAnchor.constraint(equalToConstant: 160),
        ])
    }

    /// Called by DocumentWindowController whenever the user selects a simulation's "Field Viewer"
    /// sub-entry (including re-selecting one already showing). Shows a cached result or error
    /// immediately if there is one; otherwise kicks off the (shared) Results step in the background.
    func showField(forSimulationIndex index: Int) {
        if currentIndex != index {
            stopPlayback()
            displayedSeriesKey = nil
        }
        currentIndex = index
        refreshDisplay()

        guard let document, index < document.config.simulations.count else { return }
        let name = document.config.simulations[index].name
        // request(...) is a cheap no-op if .fieldPostProcessing (and everything it depends on) is
        // already cached -- no separate hasStage(...) guard needed here the way the other two VCs
        // use one purely as an optimization; errors[index]/runningIndices still guard against
        // re-requesting while this simulation is already showing an error or mid-run.
        guard errors[index] == nil, !runningIndices.contains(index) else { return }
        JobScheduler.shared.request(document: document, simulationName: name, target: .fieldPostProcessing)
        // request() may have only queued this job behind another simulation's own in-flight run --
        // refresh again now (not just the pre-request call above) so the freshly-queued state is
        // shown immediately instead of a blank content area (see ProgressStatusView.State.queued).
        refreshDisplay()
    }

    /// Called by DocumentWindowController whenever something that would change this simulation's
    /// results changes -- see SimulationResultsViewController's identical invalidateCache for why
    /// this only clears this VC's own error state: the shared pipeline's own .results cache (and
    /// this tab's own field snapshot, invalidated together with it -- see
    /// EMSSimulationPipelineBridge's own -invalidateFromStage:) is invalidated once, centrally, by
    /// whichever caller's edit triggered it, not separately per view controller.
    func invalidateCache(forSimulationIndex index: Int) {
        errors[index] = nil
    }

    private func refreshDisplay() {
        // This is the only path that calls display(snapshot:preview:), and therefore the only path
        // that can replace FieldView.fieldSnapshot and rebuild its multi-megabyte voxel colour
        // buffer. Scheduler updates deliberately stop here while another pane is selected.
        guard isViewerVisible else { return }
        guard let currentIndex, let document, currentIndex < document.config.simulations.count else { return }
        let name = document.config.simulations[currentIndex].name
        let pipeline = document.pipeline(forSimulationNamed: name)

        let snapshots = pipeline.fieldSnapshots()
        // A completed SWMR block is viewable while the results stage is still running. Before the
        // first block is published, fieldSnapshots() is empty and the normal progress UI remains.
        if !snapshots.isEmpty {
            currentSnapshots = snapshots
            let preferredPort = selectedExcitedPortBySimulation[currentIndex]
            let selectedIndex = snapshots.firstIndex(where: { $0.excitedPort == preferredPort }) ?? 0
            let snapshot = snapshots[selectedIndex]
            selectedExcitedPortBySimulation[currentIndex] = snapshot.excitedPort
            updateSeriesSelector(snapshots: snapshots, selectedIndex: selectedIndex)
            updateLiveSeriesStatus(runningIndices.contains(currentIndex) ? latestProgress[currentIndex] : nil)
            display(snapshot: snapshot, preview: pipeline.geometryPreview())
            fieldView.isHidden = false
            progressStatus.setState(.hidden)
        } else if let error = errors[currentIndex] {
            fieldView.isHidden = true
            progressStatus.setState(.error(error))
            hideFieldSeriesControls()
        } else if runningIndices.contains(currentIndex) {
            fieldView.isHidden = true
            let progress = latestProgress[currentIndex]
            // .settingUp has no fraction of any kind to show (openEMS gives no progress hook into its
            // own setup call at all -- see EMSPipelineProgressPhase's own doc comment) -- fraction nil
            // means an animated indeterminate bar, and time-estimate text nil hides that row, instead
            // of guessing a duration.
            let isSettingUp = progress?.phase == .settingUp
            let netStatus = progress?.excitedNetName.map {
                ProgressStatusView.NetStatus(prefix: isSettingUp ? "Preparing " : "Exciting ", netName: $0)
            }
            progressStatus.setState(.progress(
                status: isSettingUp ? "Setting up Simulation…"
                    : "Running simulation…\n\nA full FDTD run can take several minutes.",
                netStatus: netStatus,
                fraction: isSettingUp ? nil : (progress?.fraction ?? 0),
                timeEstimateText: isSettingUp ? nil
                    : (timeEstimateText[currentIndex] ?? TimeRemainingFormatter.string(secondsRemaining: nil))))
            hideFieldSeriesControls()
        } else if (JobScheduler.shared.job(document: document, simulationName: name, kind: .fieldPostProcessing)
                ?? JobScheduler.shared.job(document: document, simulationName: name, kind: .simulation)
                ?? JobScheduler.shared.job(document: document, simulationName: name,
                                           kind: .geometryGeneration))?.status == .queued {
            // A job exists for this simulation but the scheduler hasn't started it yet (waiting
            // behind another simulation's own in-flight run) -- see ProgressStatusView.State.queued's
            // own doc comment for why this is shown rather than a blank content area.
            fieldView.isHidden = true
            progressStatus.setState(.queued("Waiting to start…", currentJob: JobScheduler.shared.jobs.first?.progressStatusInfo))
            hideFieldSeriesControls()
        } else {
            fieldView.isHidden = true
            progressStatus.setState(.hidden)
            hideFieldSeriesControls()
        }
    }

    private func updateSeriesSelector(snapshots: [EMSFieldSnapshot], selectedIndex: Int) {
        seriesPopUp.removeAllItems()
        for (index, snapshot) in snapshots.enumerated() {
            let title = "\(snapshot.simulationName) – \(snapshot.excitationName)"
            seriesPopUp.addItem(withTitle: title)
            seriesPopUp.lastItem?.target = self
            seriesPopUp.lastItem?.action = #selector(seriesMenuItemSelected(_:))
            seriesPopUp.lastItem?.tag = index
            seriesPopUp.lastItem?.view = FieldSeriesMenuItemView(title: title)
        }
        seriesPopUp.selectItem(at: selectedIndex)
        seriesSelectorBackground.isHidden = false
    }

    /// Once the first excitation has published frames the field itself remains usable, so the
    /// full-screen progress state is deliberately hidden. Keep a compact status beside the series
    /// selector while later excitations are being prepared/run; otherwise a differential-pair run
    /// appears to stop after its first leg during the (potentially minutes-long) opaque setup for
    /// the second one.
    private func updateLiveSeriesStatus(_ progress: EMSPipelineProgress?) {
        guard let progress, let netName = progress.excitedNetName else {
            seriesProgressStack.isHidden = true
            return
        }
        seriesProgressPrefix.stringValue = progress.phase == .settingUp ? "Preparing" : "Running"
        seriesProgressNetName.configure(name: netName,
                                        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                                        color: .secondaryLabelColor)
        seriesProgressStack.isHidden = false
    }

    private func display(snapshot: EMSFieldSnapshot, preview: EMSGeometryPreview?) {
        let seriesKey = "\(snapshot.simulationName)|\(snapshot.excitedPort)"
        let seriesChanged = displayedSeriesKey != seriesKey
        if seriesChanged {
            stopPlayback()
        }
        // Set the snapshot before the preview: preview placement reads the snapshot's board Z range.
        // A genuinely new series (including the very first one ever shown) starts at its first
        // frame; a live update to the series already being shown -- more frames published, same
        // simulationName+excitedPort -- never moves the frame the user is currently looking at.
        let targetFrame = seriesChanged ? 0 : min(fieldView.currentFrameIndex, max(snapshot.frames.count - 1, 0))
        fieldView.show(snapshot: snapshot, frameIndex: targetFrame)
        fieldView.preview = preview
        displayedSeriesKey = seriesKey
        updateTransport(for: snapshot)
    }

    @objc private func seriesSelectionChanged() {
        selectSeries(at: seriesPopUp.indexOfSelectedItem)
    }

    /// Custom-view menu items don't update NSPopUpButton's selection on their own. Their explicit
    /// action carries the snapshot index in the tag and rejoins the same path used by keyboard
    /// selection through the popup button.
    @objc private func seriesMenuItemSelected(_ sender: NSMenuItem) {
        selectSeries(at: sender.tag)
    }

    private func selectSeries(at index: Int) {
        guard let currentIndex, index >= 0,
              index < currentSnapshots.count,
              let document, currentIndex < document.config.simulations.count else { return }
        seriesPopUp.selectItem(at: index)
        let snapshot = currentSnapshots[index]
        selectedExcitedPortBySimulation[currentIndex] = snapshot.excitedPort
        let simulationName = document.config.simulations[currentIndex].name
        display(snapshot: snapshot, preview: document.pipeline(forSimulationNamed: simulationName).geometryPreview())
    }

    // MARK: - Playback transport

    /// Shows/refreshes the transport bar for the selected series. A genuine series change starts at
    /// its final captured frame; unrelated UI refreshes preserve the user's playback position.
    private func updateTransport(for snapshot: EMSFieldSnapshot) {
        let frames = snapshot.frames
        currentFrames = frames
        guard frames.count > 1 else {
            hideTransport()
            return
        }
        transportBackground.isHidden = false
        frameSlider.minValue = 0
        frameSlider.maxValue = Double(frames.count - 1)
        frameSlider.integerValue = fieldView.currentFrameIndex
        updateFrameLabel()
        updatePlayPauseIcon()
    }

    private func hideTransport() {
        transportBackground.isHidden = true
        stopPlayback()
        currentFrames = []
    }

    private func hideFieldSeriesControls() {
        seriesSelectorBackground.isHidden = true
        seriesProgressStack.isHidden = true
        currentSnapshots = []
        displayedSeriesKey = nil
        hideTransport()
    }

    @objc private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
        updatePlayPauseIcon()
    }

    /// Fixed-interval playback rather than real-time-scaled -- each frame's own timeSeconds spacing
    /// is highly non-uniform (see CopperFDTDRunner.cpp's own capture cadence: wall-clock-triggered,
    /// not evenly spaced in simulation time), so mapping to real elapsed simulation time would make
    /// playback speed lurch around; a flat per-frame interval reads as smooth motion instead.
    private func startPlayback() {
        guard currentFrames.count > 1 else { return }
        isPlaying = true
        fieldView.setPlaybackActive(true)
        // If already at the last frame, restart from the beginning rather than doing nothing.
        if fieldView.currentFrameIndex >= currentFrames.count - 1 {
            setFrame(0)
        }
        schedulePlaybackAdvance()
    }

    /// Arm each interval only after the previous frame has actually been installed. A repeating
    /// timer measures from its scheduled fire date, so a slower buffer upload can otherwise make
    /// the following frame flash past in less than 100ms while the timer catches up.
    private func schedulePlaybackAdvance() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: Self.playbackInterval, repeats: false) { [weak self] _ in
            self?.advanceFrame()
        }
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
        fieldView.setPlaybackActive(false)
    }

    private func advanceFrame() {
        guard !currentFrames.isEmpty else { return }
        let next = fieldView.currentFrameIndex + 1
        guard next < currentFrames.count else {
            stopPlayback()
            updatePlayPauseIcon()
            return
        }
        setFrame(next)
        if isPlaying { schedulePlaybackAdvance() }
    }

    @objc private func sliderChanged() {
        stopPlayback()
        updatePlayPauseIcon()
        setFrame(frameSlider.integerValue)
    }

    private func setFrame(_ index: Int) {
        fieldView.currentFrameIndex = index
        frameSlider.integerValue = index
        updateFrameLabel()
    }

    private func updateFrameLabel() {
        guard !currentFrames.isEmpty else {
            frameLabel.stringValue = ""
            return
        }
        let index = min(max(fieldView.currentFrameIndex, 0), currentFrames.count - 1)
        let frame = currentFrames[index]
        let nanoseconds = frame.timeSeconds * 1e9
        frameLabel.stringValue = String(format: "Frame %d/%d — %.2f ns", index + 1, currentFrames.count, nanoseconds)
    }

    private func updatePlayPauseIcon() {
        let name = isPlaying ? "pause.fill" : "play.fill"
        let description = isPlaying ? "Pause" : "Play"
        playPauseButton.image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    /// Called from JobScheduler.shared's onChange notification -- see
    /// GeometryViewController.syncFromScheduler()'s identical-in-spirit doc comment. Watches all
    /// three of this simulation's own prerequisite jobs (.geometryGeneration -> .simulation ->
    /// .fieldPostProcessing), not just the last one -- the real, potentially slow FDTD work happens
    /// in the first two, well before .fieldPostProcessing's own (near-instant) job ever exists, so
    /// this VC's "is something in progress for me" state has to track whichever of the three is
    /// currently the active one, the same way SimulationResultsViewController does for its own
    /// two-job chain. progressReceived(...) here is already phase-agnostic for its own *content-pane*
    /// display purposes (just fraction/time estimate, no per-phase row of its own to choose between),
    /// so forwarding progress from any of the three through it unchanged is correct as-is -- but
    /// `activeJob.kind` is still threaded through every onRunStateChanged/onProgressChanged/
    /// onRunFinished/onRunCancelled call below, so DocumentWindowController can tell which of the
    /// three is actually being reported and only relay `.fieldPostProcessing` ones to the sidebar's
    /// own Field Viewer row (see those properties' own doc comments).
    private func syncFromScheduler() {
        guard let document else { return }
        for index in 0..<document.config.simulations.count {
            let name = document.config.simulations[index].name
            let pipeline = document.pipeline(forSimulationNamed: name)
            let geometryJob = JobScheduler.shared.job(document: document, simulationName: name, kind: .geometryGeneration)
            let simulationJob = JobScheduler.shared.job(document: document, simulationName: name, kind: .simulation)
            let fieldJob = JobScheduler.shared.job(document: document, simulationName: name, kind: .fieldPostProcessing)
            let activeJob = fieldJob ?? simulationJob ?? geometryJob
            let wasRunning = runningIndices.contains(index)

            switch activeJob?.status {
            case .running, .cancelling:
                guard let activeJob else { continue }
                // Recorded on every tick, not just the `!wasRunning` transition below -- `activeJob`
                // can silently move from one JobKind to the next (e.g. geometry finishes, its Job is
                // removed, the simulation Job takes over as `activeJob`) with no onRunStateChanged
                // transition of its own to hang the update off of, so onProgressChanged must always
                // report whichever kind is *currently* driving this tick.
                runningJobKind[index] = activeJob.kind
                if !wasRunning {
                    runningIndices.insert(index)
                    runStartTime[index] = Date()
                    onRunStateChanged?(index, activeJob.kind, true)
                    refreshDisplay()
                }
                if let progress = activeJob.progress {
                    progressReceived(progress, forSimulationIndex: index, kind: activeJob.kind)
                }

            case .failed(let message):
                guard wasRunning, let activeJob else { continue }
                let kind = activeJob.kind
                finishTracking(forSimulationIndex: index, kind: kind)
                errors[index] = message
                onRunFinished?(index, kind, false)
                JobScheduler.shared.dismiss(jobID: activeJob.id)
                refreshDisplay()

            case .queued, nil:
                guard wasRunning, let kind = runningJobKind[index] else { continue }
                finishTracking(forSimulationIndex: index, kind: kind)
                if !pipeline.fieldSnapshots().isEmpty {
                    onRunFinished?(index, kind, true)
                } else {
                    onRunCancelled?(index, kind)
                }
                refreshDisplay()
            }
        }
        // Keeps the "Current Job: ..." sub-section (see ProgressStatusView's own doc comment) live
        // while this simulation's own job sits queued behind some *other* simulation's in-flight
        // run -- see GeometryViewController.syncFromScheduler()'s identical trailing check for why
        // this is scoped to !runningIndices.contains (avoiding cancelling progressReceived()'s own
        // animated update above when this VC's own job is the one actually running).
        if let currentIndex, !runningIndices.contains(currentIndex), errors[currentIndex] == nil {
            refreshDisplay()
        }
    }

    private func finishTracking(forSimulationIndex index: Int, kind: JobKind) {
        runningIndices.remove(index)
        latestProgress[index] = nil
        runStartTime[index] = nil
        timeEstimateText[index] = nil
        runningJobKind[index] = nil
        onRunStateChanged?(index, kind, false)
    }

    private func progressReceived(_ progress: EMSPipelineProgress, forSimulationIndex index: Int, kind: JobKind) {
        latestProgress[index] = progress
        onProgressChanged?(index, kind, progress)
        // .settingUp (openEMS's own silent SetupFDTD() call -- see EMSPipelineProgressPhase's own doc
        // comment) has no fraction of any kind to extrapolate a remaining time from -- refreshDisplay()
        // shows a plain indeterminate bar and no time-estimate text for it instead of guessing.
        if progress.phase != .settingUp {
            let secondsRemaining: Double?
            if let start = runStartTime[index], progress.fraction > 0 {
                let elapsed = Date().timeIntervalSince(start)
                secondsRemaining = max(0, elapsed / progress.fraction - elapsed)
            } else {
                secondsRemaining = nil
            }
            timeEstimateText[index] = TimeRemainingFormatter.string(secondsRemaining: secondsRemaining)
        }
        if currentIndex == index, runningIndices.contains(index) {
            // This both updates the ordinary progress state and reopens the SWMR series to discover
            // a newly-published frame block. Once one exists, the field replaces the progress UI.
            refreshDisplay()
        }
    }
}
