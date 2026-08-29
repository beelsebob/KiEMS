import Cocoa

/// A self-contained "this content isn't ready yet" status display -- shared by every simulation-
/// pipeline-stage content view (Geometry/Simulation Results/Field Viewer) instead of each hand-
/// rolling its own statusLabel/progressBar/timeEstimateLabel plus the vertical-centering layout,
/// as they used to (three independently-maintained, near-byte-identical copies). Each owning view
/// controller still owns its own "is my data ready" state machine (JobScheduler + pipeline stage
/// checks) -- this view only owns how to *display* whichever not-ready state that machine is in.
///
/// A caller needing extra accessory content alongside the core status/progress display (e.g.
/// SimulationResultsViewController's excitation icon and energy-decay level indicator) can anchor
/// its own subviews directly to this view's public `progressBar`/`timeEstimateLabel` -- both live
/// inside this view's own hierarchy but are exposed for exactly that purpose, the same way the
/// original per-VC implementations positioned those accessories relative to their own local
/// progress bar.
final class ProgressStatusView: NSView {
    /// The scheduler's own currently-running job, shown under a `.queued` state's own barber pole --
    /// see State.queued's own doc comment for why. `label` is the caller's own already-composed
    /// "Current Job: ..." text (this view stays agnostic of JobScheduler/JobKind specifics, matching
    /// how every other state here is just plain display data, not a live query of its own).
    struct CurrentJobInfo {
        let label: String
        let fraction: Double?
        let timeEstimateText: String?
    }

    enum State {
        /// Nothing to show -- the caller's own real content view should be visible instead.
        case hidden
        /// Plain centered text, no progress bar -- e.g. "No results to display."
        case message(String)
        /// Same as `.message`, but rendered via NetNameFormatting so an embedded net name's own
        /// markup (sub/superscript, negation, an escaped "/") renders correctly instead of as
        /// literal, unformatted tokens -- see NetNameFormatting.attributedString(embeddingNetNamesIn:).
        case error(String)
        /// A job exists for this content but the scheduler hasn't started it yet (JobStatus.queued,
        /// e.g. waiting behind another simulation's own in-flight run, or an earlier stage in this
        /// simulation's own chain) -- distinct from `.hidden`/`.message` so a merely-queued job still
        /// shows *something*, rather than a blank content area indistinguishable from "nothing was
        /// ever requested" (the bug this view was introduced to fix -- selecting a tab whose job sits
        /// queued for a while used to show nothing at all until it actually started running).
        /// `currentJob`, when non-nil, shows what's actually occupying the scheduler right now below
        /// the barber pole -- otherwise "Waiting to start…" on its own gives no sense of whether
        /// anything is actually happening or how long this might sit queued.
        case queued(String, currentJob: CurrentJobInfo? = nil)
        /// An in-flight job. `fraction` nil means indeterminate (e.g. openEMS's own setup phase,
        /// which has no progress hook at all -- see EMSPipelineProgressPhase's own doc comment).
        /// `timeEstimateText` nil hides the time-estimate row entirely (no text ever flashes in then
        /// out, which would read as flickering) rather than showing an empty/placeholder string.
        case progress(status: String, fraction: Double?, timeEstimateText: String?)
    }

    let progressBar = NSProgressIndicator()
    let timeEstimateLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    // The "Current Job: ..." sub-section, shown only for a `.queued` state whose currentJob is
    // non-nil -- a horizontal rule, a label, and its own progress bar/time estimate, mirroring the
    // main status display's own style/layout exactly ("show the progress ... like you would
    // normally"). Grouped under one stack view (currentJobStack) so hiding it collapses its space
    // entirely rather than leaving a gap -- see stack's own doc comment for why the whole content
    // area uses this same trick.
    private let currentJobSeparator = NSView()
    private let currentJobLabel = NSTextField(labelWithString: "")
    private let currentJobProgressBar = NSProgressIndicator()
    private let currentJobTimeEstimateLabel = NSTextField(labelWithString: "")
    private var currentJobStack: NSStackView!

    private var stack: NSStackView!
    private(set) var state: State = .hidden

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        statusLabel.font = .systemFont(ofSize: 20, weight: .medium)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        // Without this, a multi-line NSTextField's intrinsicContentSize is computed before Auto
        // Layout has resolved its actual available width -- it can't know where to wrap yet, so it
        // falls back to reporting its full *unwrapped* single-line width as intrinsic, which an
        // Auto-Layout-sized window then grows to accommodate (a real, previously-hit bug: a verbose
        // error message ballooning the whole window).
        statusLabel.preferredMaxLayoutWidth = 400

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 240).isActive = true

        timeEstimateLabel.font = .systemFont(ofSize: 11)
        timeEstimateLabel.textColor = .tertiaryLabelColor
        timeEstimateLabel.alignment = .center

        currentJobSeparator.wantsLayer = true
        currentJobSeparator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        currentJobSeparator.translatesAutoresizingMaskIntoConstraints = false
        currentJobSeparator.widthAnchor.constraint(equalToConstant: 240).isActive = true
        currentJobSeparator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        currentJobLabel.font = .systemFont(ofSize: 12, weight: .medium)
        currentJobLabel.textColor = .secondaryLabelColor
        currentJobLabel.alignment = .center
        currentJobLabel.lineBreakMode = .byWordWrapping
        currentJobLabel.maximumNumberOfLines = 0
        currentJobLabel.preferredMaxLayoutWidth = 400

        currentJobProgressBar.style = .bar
        currentJobProgressBar.isIndeterminate = false
        currentJobProgressBar.minValue = 0
        currentJobProgressBar.maxValue = 1
        currentJobProgressBar.translatesAutoresizingMaskIntoConstraints = false
        currentJobProgressBar.widthAnchor.constraint(equalToConstant: 240).isActive = true

        currentJobTimeEstimateLabel.font = .systemFont(ofSize: 11)
        currentJobTimeEstimateLabel.textColor = .tertiaryLabelColor
        currentJobTimeEstimateLabel.alignment = .center

        // A nested vertical stack for just the current-job sub-section, itself one arranged subview
        // of the outer `stack` -- letting the whole group collapse/reappear as one unit (see its own
        // isHidden usage in setState) without needing to juggle 4 separate hidden-row spacings.
        currentJobStack = NSStackView(views: [
            currentJobSeparator, currentJobLabel, currentJobProgressBar, currentJobTimeEstimateLabel,
        ])
        currentJobStack.orientation = .vertical
        currentJobStack.alignment = .centerX
        currentJobStack.spacing = 6
        // Extra breathing room above the rule, matching the gap the main block's own statusLabel-to-
        // progressBar spacing already reads as -- set via the outer stack's setCustomSpacing below
        // (this stack's own top-of-first-arrangedSubview spacing is handled by the outer stack's gap
        // to *this whole stack*, not by an internal edge inset here).

        // One outer vertical stack holds everything -- NSStackView automatically removes a hidden
        // arranged subview from layout entirely (unlike a plain NSView's constraints, which keep
        // reserving its space even while isHidden -- the exact "empty gap" bug the original three
        // hand-rolled implementations, and an early draft of this view, had to work around with a
        // manually-sized NSLayoutGuide). Centering just this one stack vertically replaces that
        // NSLayoutGuide trick entirely: whatever rows are actually visible, the stack's own natural
        // height is exactly their combined height, so a plain centerYAnchor is enough.
        stack = NSStackView(views: [statusLabel, progressBar, timeEstimateLabel, currentJobStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: statusLabel)
        stack.setCustomSpacing(6, after: progressBar)
        stack.setCustomSpacing(16, after: timeEstimateLabel)
        currentJobStack.setCustomSpacing(4, after: currentJobLabel)
        currentJobStack.setCustomSpacing(6, after: currentJobProgressBar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        setState(.hidden)
    }

    /// `animated` smooths just `.progress`'s own determinate-fraction transition (and the current-job
    /// sub-section's, under `.queued`) -- meant for live incremental ticks within the same in-flight
    /// job, not for a state *kind* change (those jump instead: an animated slide would misleadingly
    /// suggest continuity between two unrelated values, e.g. one job's final progress sliding into
    /// another's starting point, or a phase-boundary reset reading as "half complete" instead of
    /// genuinely restarting from scratch).
    func setState(_ newState: State, animated: Bool = false) {
        state = newState
        if case .hidden = newState {
            isHidden = true
        } else {
            isHidden = false
        }
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        currentJobStack.isHidden = true

        switch newState {
        case .hidden:
            break

        case .message(let text):
            statusLabel.stringValue = text
            statusLabel.isHidden = false
            progressBar.isHidden = true
            timeEstimateLabel.isHidden = true

        case .error(let message):
            statusLabel.attributedStringValue = NetNameFormatting.attributedString(
                embeddingNetNamesIn: message, font: statusLabel.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            statusLabel.isHidden = false
            progressBar.isHidden = true
            timeEstimateLabel.isHidden = true

        case .queued(let text, let currentJob):
            statusLabel.stringValue = text
            statusLabel.isHidden = false
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            progressBar.isHidden = false
            timeEstimateLabel.isHidden = true
            if let currentJob {
                applyCurrentJob(currentJob, animated: animated)
                currentJobStack.isHidden = false
            }

        case .progress(let status, let fraction, let timeEstimateText):
            statusLabel.stringValue = status
            statusLabel.isHidden = false
            if let fraction {
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        progressBar.animator().doubleValue = fraction
                    }
                } else {
                    progressBar.doubleValue = fraction
                }
            } else {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
            progressBar.isHidden = false
            if let timeEstimateText {
                timeEstimateLabel.stringValue = timeEstimateText
                timeEstimateLabel.isHidden = false
            } else {
                timeEstimateLabel.isHidden = true
            }
        }
    }

    private func applyCurrentJob(_ currentJob: CurrentJobInfo, animated: Bool) {
        currentJobLabel.stringValue = "Current Job: \(currentJob.label)"
        currentJobProgressBar.stopAnimation(nil)
        if let fraction = currentJob.fraction {
            currentJobProgressBar.isIndeterminate = false
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    currentJobProgressBar.animator().doubleValue = fraction
                }
            } else {
                currentJobProgressBar.doubleValue = fraction
            }
        } else {
            currentJobProgressBar.isIndeterminate = true
            currentJobProgressBar.startAnimation(nil)
        }
        if let timeEstimateText = currentJob.timeEstimateText {
            currentJobTimeEstimateLabel.stringValue = timeEstimateText
            currentJobTimeEstimateLabel.isHidden = false
        } else {
            currentJobTimeEstimateLabel.isHidden = true
        }
    }
}
