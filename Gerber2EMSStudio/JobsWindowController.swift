import Cocoa

/// One row's view: a title ("simulation — kind"), a status area (a determinate progress bar while
/// running, a plain text label otherwise), and a small borderless (x) button. Frame-based layout for
/// the icon/button, matching SourceListIconCellView's own established pattern in this app rather
/// than Auto Layout for a fixed-size trailing control.
private final class JobRowCellView: NSTableCellView {
    private static let buttonExtent: CGFloat = 16
    private static let trailingInset: CGFloat = 8

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton()

    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)

        cancelButton.bezelStyle = .regularSquare
        cancelButton.isBordered = false
        cancelButton.imagePosition = .imageOnly
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            progressBar.trailingAnchor.constraint(
                lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),
            progressBar.widthAnchor.constraint(equalToConstant: 200),

            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: Self.buttonExtent),
            cancelButton.heightAnchor.constraint(equalToConstant: Self.buttonExtent),
        ])
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    func configure(job: Job, title: String) {
        titleLabel.stringValue = title
        switch job.status {
        case .queued:
            statusLabel.isHidden = false
            progressBar.isHidden = true
            statusLabel.stringValue = "Queued"
        case .running:
            statusLabel.isHidden = true
            progressBar.isHidden = false
            progressBar.doubleValue = job.progress?.fraction ?? 0
        case .cancelling:
            statusLabel.isHidden = false
            progressBar.isHidden = true
            statusLabel.stringValue = "Cancelling…"
        case .failed(let message):
            statusLabel.isHidden = false
            progressBar.isHidden = true
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
        }
        if case .failed = job.status {
            // Left red from the branch above.
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }
        cancelButton.isEnabled = job.status != .cancelling
    }
}

/// A single, app-wide, priority-ordered list of every job JobScheduler is tracking, across every
/// open document -- see JobScheduler's own top comment for the model this displays. The first
/// (and, as of this feature, only) second window this app has ever had; a plain NSWindowController
/// owned by AppDelegate for the app's whole lifetime (shown/hidden, never deallocated), since
/// there's no per-document ownership that would make sense for something spanning every open
/// document.
final class JobsWindowController: NSWindowController {
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No jobs")

    private static let columnIdentifier = NSUserInterfaceItemIdentifier("job")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jobs"
        // Keeps its own position/size across show/hide -- a utility window the user re-opens
        // repeatedly should reappear where they last left it, not recenter every time.
        window.setFrameAutosaveName("JobsWindow")
        self.init(window: window)
        buildUI()
        JobScheduler.shared.addChangeObserver { [weak self] in self?.reload() }
        reload()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.title = "Job"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.delegate = self
        tableView.dataSource = self
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = true
        // Double-clicking a job jumps the owning document's main window to that job's
        // simulation+sub-entry -- see jobDoubleClicked().
        tableView.target = self
        tableView.doubleAction = #selector(jobDoubleClicked)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    private func reload() {
        let jobs = JobScheduler.shared.jobs
        emptyLabel.isHidden = !jobs.isEmpty
        tableView.reloadData()
    }

    /// (x) tapped for `job` -- previews what else would be cancelled along with it and, if anything
    /// would, confirms with the user first (the user's own explicit requirement: "an alert should be
    /// presented to confirm, and all dependent tasks deleted"). A job with no dependents (the common
    /// case -- the last one in its own chain, or the only job queued for its simulation) cancels
    /// immediately with no prompt.
    fileprivate func requestCancel(jobID: UUID, description: String) {
        let dependents = JobScheduler.shared.previewCancel(jobID: jobID)
        guard !dependents.isEmpty else {
            JobScheduler.shared.confirmCancel(jobID: jobID)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Cancel \(description)?"
        let dependentList = dependents.map { "\($0.simulationName) — \($0.kind.displayName)" }.joined(separator: "\n")
        alert.informativeText = "The following queued job(s) depend on this and will also be cancelled:\n\n\(dependentList)"
        alert.addButton(withTitle: "Cancel Jobs")
        alert.addButton(withTitle: "Keep")
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                JobScheduler.shared.confirmCancel(jobID: jobID)
            }
        }
    }

    /// Double-clicked a job row -- bring that job's own document window to the front and jump its
    /// main UI to the simulation+sub-entry this job represents (Geometry / Simulation Results /
    /// Field Viewer). No-op if the document is already gone (job.document is weak and nil'd on close)
    /// or has no window controller.
    @objc private func jobDoubleClicked() {
        let row = tableView.clickedRow
        let jobs = JobScheduler.shared.jobs
        guard row >= 0, row < jobs.count else { return }
        let job = jobs[row]
        guard let document = job.document,
              let windowController = document.windowControllers.first as? DocumentWindowController else { return }
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.selectJob(kind: job.kind, forSimulationNamed: job.simulationName)
    }
}

extension JobsWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        JobScheduler.shared.jobs.count
    }
}

extension JobsWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let jobs = JobScheduler.shared.jobs
        guard row < jobs.count else { return nil }
        let job = jobs[row]
        let cell = tableView.makeView(withIdentifier: Self.columnIdentifier, owner: self) as? JobRowCellView ?? {
            let cell = JobRowCellView()
            cell.identifier = Self.columnIdentifier
            return cell
        }()
        let title = "\(job.simulationName) — \(job.kind.displayName)"
        cell.configure(job: job, title: title)
        cell.onCancel = { [weak self] in
            self?.requestCancel(jobID: job.id, description: title)
        }
        return cell
    }
}
