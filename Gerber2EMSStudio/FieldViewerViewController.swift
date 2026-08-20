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
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let timeEstimateLabel = NSTextField(labelWithString: "")

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
    /// GeometryViewController's identical property for the intended DocumentWindowController relay
    /// (not currently wired to the source-list row's own spinner -- see SimulationListViewController's
    /// own doc comment on the Field Viewer row still being a static "Not a pipeline stage yet" --
    /// kept here anyway for parity/future wiring, matching this codebase's other view controllers).
    var onRunStateChanged: ((Int, Bool) -> Void)?
    var onRunFinished: ((Int, Bool) -> Void)?
    var onProgressChanged: ((Int, EMSPipelineProgress) -> Void)?

    init(document: Document) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        fieldView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fieldView)

        statusLabel.font = .systemFont(ofSize: 20, weight: .medium)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.preferredMaxLayoutWidth = 400
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressBar)

        timeEstimateLabel.font = .systemFont(ofSize: 11)
        timeEstimateLabel.textColor = .tertiaryLabelColor
        timeEstimateLabel.alignment = .center
        timeEstimateLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(timeEstimateLabel)

        let contentGuide = NSLayoutGuide()
        container.addLayoutGuide(contentGuide)

        NSLayoutConstraint.activate([
            fieldView.topAnchor.constraint(equalTo: container.topAnchor),
            fieldView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fieldView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fieldView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentGuide.topAnchor.constraint(equalTo: statusLabel.topAnchor),
            contentGuide.bottomAnchor.constraint(equalTo: timeEstimateLabel.bottomAnchor),
            contentGuide.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            progressBar.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            progressBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 240),

            timeEstimateLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            timeEstimateLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
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
        let pipeline = document.pipeline(forSimulationNamed: name)
        guard !pipeline.hasStage(.results), errors[index] == nil, !runningIndices.contains(index) else { return }
        runStep(forSimulationIndex: index, simulationName: name, pipeline: pipeline)
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
            statusLabel.isHidden = true
            progressBar.isHidden = true
            timeEstimateLabel.isHidden = true
            updateTransport(for: snapshot)
        } else if let error = errors[currentIndex] {
            fieldView.isHidden = true
            statusLabel.stringValue = error
            statusLabel.isHidden = false
            progressBar.isHidden = true
            timeEstimateLabel.isHidden = true
            hideTransport()
        } else if runningIndices.contains(currentIndex) {
            fieldView.isHidden = true
            statusLabel.stringValue = "Running simulation…\n\nA full FDTD run can take several minutes."
            statusLabel.isHidden = false
            progressBar.doubleValue = latestProgress[currentIndex]?.fraction ?? 0
            progressBar.isHidden = false
            timeEstimateLabel.stringValue = timeEstimateText[currentIndex]
                ?? TimeRemainingFormatter.string(secondsRemaining: nil)
            timeEstimateLabel.isHidden = false
            hideTransport()
        } else {
            fieldView.isHidden = true
            statusLabel.isHidden = true
            progressBar.isHidden = true
            timeEstimateLabel.isHidden = true
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

    private func runStep(forSimulationIndex index: Int, simulationName: String, pipeline: EMSSimulationPipelineBridge) {
        guard let document else { return }
        let config = document.config
        let packageDir = document.pipelineDirectory.path
        let kicadCliPath = AppPaths.resolveKicadCli()
        let helperPath = AppPaths.kicadQueryHelperPath

        runningIndices.insert(index)
        runStartTime[index] = Date()
        onRunStateChanged?(index, true)
        refreshDisplay()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try pipeline.ensureStage(.results, config: config, packageDir: packageDir,
                                          kicadCliPath: kicadCliPath, kicadQueryHelperPath: helperPath,
                                          progress: { progress in
                                              DispatchQueue.main.async {
                                                  self?.progressReceived(progress, forSimulationIndex: index)
                                              }
                                          })
                DispatchQueue.main.async {
                    self?.stepFinished(forSimulationIndex: index, error: nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.stepFinished(forSimulationIndex: index, error: error)
                }
            }
        }
    }

    private func progressReceived(_ progress: EMSPipelineProgress, forSimulationIndex index: Int) {
        latestProgress[index] = progress
        onProgressChanged?(index, progress)
        let secondsRemaining: Double?
        if let start = runStartTime[index], progress.fraction > 0 {
            let elapsed = Date().timeIntervalSince(start)
            secondsRemaining = max(0, elapsed / progress.fraction - elapsed)
        } else {
            secondsRemaining = nil
        }
        let estimateText = TimeRemainingFormatter.string(secondsRemaining: secondsRemaining)
        timeEstimateText[index] = estimateText
        if currentIndex == index, runningIndices.contains(index) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                progressBar.animator().doubleValue = progress.fraction
            }
            timeEstimateLabel.stringValue = estimateText
        }
    }

    private func stepFinished(forSimulationIndex index: Int, error: Error?) {
        runningIndices.remove(index)
        latestProgress[index] = nil
        runStartTime[index] = nil
        timeEstimateText[index] = nil
        progressBar.doubleValue = 0
        onRunStateChanged?(index, false)
        onRunFinished?(index, error == nil)
        if let error {
            errors[index] = error.localizedDescription
        }
        refreshDisplay()
    }
}
