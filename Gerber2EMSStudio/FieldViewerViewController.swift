import Cocoa

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
    private static let playbackInterval: TimeInterval = 0.12

    private var errors: [Int: String] = [:]
    private var runningIndices: Set<Int> = []
    private var latestProgress: [Int: EMSPipelineProgress] = [:]
    private var runStartTime: [Int: Date] = [:]
    private var timeEstimateText: [Int: String] = [:]
    private var currentIndex: Int?

    /// Fired whenever a given simulation's Field Viewer step starts/finishes running -- see
    /// GeometryViewController's identical property. Now genuinely wired to the source-list row's own
    /// spinner (see SimulationListViewController.setFieldViewerRowBusy/etc.) -- JobScheduler tracks
    /// .fieldPostProcessing as a real job, so the Field Viewer row is no longer the static "Not a
    /// pipeline stage yet" placeholder it used to be.
    var onRunStateChanged: ((Int, Bool) -> Void)?
    var onRunFinished: ((Int, Bool) -> Void)?
    var onProgressChanged: ((Int, EMSPipelineProgress) -> Void)?
    /// See GeometryViewController.onRunCancelled's identical doc comment.
    var onRunCancelled: ((Int) -> Void)?

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
        JobScheduler.shared.addChangeObserver { [weak self] in self?.syncFromScheduler() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        view = container
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
        guard let currentIndex, let document, currentIndex < document.config.simulations.count else { return }
        let name = document.config.simulations[currentIndex].name
        let pipeline = document.pipeline(forSimulationNamed: name)

        if pipeline.hasStage(.results), let snapshot = pipeline.fieldSnapshot() {
            // fieldSnapshot before preview, not the other way round -- preview's own didSet reads
            // fieldSnapshot?.boardZMax/boardZMin synchronously (see FieldView.rebuildOverlayBuffers())
            // to place each copper layer at its own real Z; setting preview first left it reading
            // whatever fieldSnapshot was *before* this call (nil on the very first display), which is
            // exactly what was producing a silently-zero board thickness despite EMSFieldSnapshot
            // itself carrying the real value all along.
            fieldView.fieldSnapshot = snapshot
            fieldView.preview = pipeline.geometryPreview()
            fieldView.isHidden = false
            progressStatus.setState(.hidden)
            updateTransport(for: snapshot)
        } else if let error = errors[currentIndex] {
            fieldView.isHidden = true
            progressStatus.setState(.error(error))
            hideTransport()
        } else if runningIndices.contains(currentIndex) {
            fieldView.isHidden = true
            let progress = latestProgress[currentIndex]
            // .settingUp has no fraction of any kind to show (openEMS gives no progress hook into its
            // own setup call at all -- see EMSPipelineProgressPhase's own doc comment) -- fraction nil
            // means an animated indeterminate bar, and time-estimate text nil hides that row, instead
            // of guessing a duration.
            let isSettingUp = progress?.phase == .settingUp
            progressStatus.setState(.progress(
                status: isSettingUp ? "Setting up Simulation…"
                    : "Running simulation…\n\nA full FDTD run can take several minutes.",
                fraction: isSettingUp ? nil : (progress?.fraction ?? 0),
                timeEstimateText: isSettingUp ? nil
                    : (timeEstimateText[currentIndex] ?? TimeRemainingFormatter.string(secondsRemaining: nil))))
            hideTransport()
        } else if (JobScheduler.shared.job(document: document, simulationName: name, kind: .fieldPostProcessing)
                ?? JobScheduler.shared.job(document: document, simulationName: name, kind: .simulation)
                ?? JobScheduler.shared.job(document: document, simulationName: name,
                                           kind: .geometryGeneration))?.status == .queued {
            // A job exists for this simulation but the scheduler hasn't started it yet (waiting
            // behind another simulation's own in-flight run) -- see ProgressStatusView.State.queued's
            // own doc comment for why this is shown rather than a blank content area.
            fieldView.isHidden = true
            progressStatus.setState(.queued("Waiting to start…", currentJob: JobScheduler.shared.jobs.first?.progressStatusInfo))
            hideTransport()
        } else {
            fieldView.isHidden = true
            progressStatus.setState(.hidden)
            hideTransport()
        }
    }

    // MARK: - Playback transport

    /// Shows/refreshes the transport bar for a newly-(re)fetched EMSFieldSnapshot -- called on every
    /// refreshDisplay() while results are available, not just the first time (pipeline.fieldSnapshot()
    /// hands back a freshly-built object each call, see EMSSimulationPipelineBridge's own -fieldSnapshot
    /// accessor), so this only resets scrub position/play state when the frame count itself changed,
    /// preserving whatever the user was doing across an otherwise-unrelated refresh.
    private func updateTransport(for snapshot: EMSFieldSnapshot) {
        let frames = snapshot.frames
        let frameCountChanged = frames.count != currentFrames.count
        currentFrames = frames
        guard frames.count > 1 else {
            hideTransport()
            return
        }
        transportBackground.isHidden = false
        frameSlider.minValue = 0
        frameSlider.maxValue = Double(frames.count - 1)
        if frameCountChanged {
            fieldView.currentFrameIndex = frames.count - 1
        }
        frameSlider.integerValue = fieldView.currentFrameIndex
        updateFrameLabel()
        updatePlayPauseIcon()
    }

    private func hideTransport() {
        transportBackground.isHidden = true
        stopPlayback()
        currentFrames = []
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
        // If already at the last frame, restart from the beginning rather than doing nothing.
        if fieldView.currentFrameIndex >= currentFrames.count - 1 {
            setFrame(0)
        }
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: Self.playbackInterval, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
    }

    private func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
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
    /// two-job chain. progressReceived(...) here is already phase-agnostic (just fraction/time
    /// estimate, no per-phase row to choose between), so forwarding progress from any of the three
    /// through it unchanged is correct as-is.
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
                if !wasRunning {
                    runningIndices.insert(index)
                    runStartTime[index] = Date()
                    onRunStateChanged?(index, true)
                    refreshDisplay()
                }
                if let progress = activeJob?.progress {
                    progressReceived(progress, forSimulationIndex: index)
                }

            case .failed(let message):
                guard wasRunning else { continue }
                finishTracking(forSimulationIndex: index)
                errors[index] = message
                onRunFinished?(index, false)
                if let jobID = activeJob?.id { JobScheduler.shared.dismiss(jobID: jobID) }
                refreshDisplay()

            case .queued, nil:
                guard wasRunning else { continue }
                finishTracking(forSimulationIndex: index)
                if pipeline.fieldSnapshot() != nil {
                    onRunFinished?(index, true)
                } else {
                    onRunCancelled?(index)
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

    private func finishTracking(forSimulationIndex index: Int) {
        runningIndices.remove(index)
        latestProgress[index] = nil
        runStartTime[index] = nil
        timeEstimateText[index] = nil
        onRunStateChanged?(index, false)
    }

    private func progressReceived(_ progress: EMSPipelineProgress, forSimulationIndex index: Int) {
        latestProgress[index] = progress
        onProgressChanged?(index, progress)
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
            let isSettingUp = progress.phase == .settingUp
            progressStatus.setState(.progress(
                status: isSettingUp ? "Setting up Simulation…"
                    : "Running simulation…\n\nA full FDTD run can take several minutes.",
                fraction: isSettingUp ? nil : progress.fraction,
                timeEstimateText: isSettingUp ? nil
                    : (timeEstimateText[index] ?? TimeRemainingFormatter.string(secondsRemaining: nil))),
                animated: true)
        }
    }
}
