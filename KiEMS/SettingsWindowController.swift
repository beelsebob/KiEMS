import Cocoa

/// KiEMS > Settings…: app-wide preferences -- how simulations store their field frames (see
/// FieldFramePreferences) and whether the Mac stays awake while jobs run (see PowerPreferences). Changes save immediately and apply to simulations run afterwards.
final class SettingsWindowController: NSWindowController {
    private let precisionPopUp = NSPopUpButton()
    private let channelsPopUp = NSPopUpButton()
    private let intervalField = NSTextField(string: "")
    private let intervalStepper = NSStepper()
    private let sizeLabel = NSTextField(labelWithString: "")
    /// "In File", then the chosen folder (when there is one), then "Choose Folder…".
    private let directoryPopUp = NSPopUpButton()
    private let keepAwakeCheckbox = NSButton(checkboxWithTitle: "Keep the Mac awake and at full performance while jobs run",
                                             target: nil, action: nil)

    private static let precisions: [(EMSFieldFramePrecision, String, Int)] = [
        (.int8, "Int8", 1), (.int12, "Int12", 2), (.float16, "Float16", 2), (.float32, "Float32 (lossless)", 4),
    ]
    private static let channelChoices: [(EMSFieldFrameChannels, String, Int)] = [
        (.allComponents, "All 6 channels (Ex, Ey, Ez, Hx, Hy, Hz)", 6), (.energy, "Combined energy only", 1),
    ]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        super.init(window: window)
        buildUI()
        reload()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        precisionPopUp.addItems(withTitles: Self.precisions.map(\.1))
        precisionPopUp.target = self
        precisionPopUp.action = #selector(precisionChanged)
        precisionPopUp.toolTip = "Int8, Int12 and Float16 store each frame's values relative to that frame's "
            + "peak; Float32 keeps them exactly."

        channelsPopUp.addItems(withTitles: Self.channelChoices.map(\.1))
        channelsPopUp.target = self
        channelsPopUp.action = #selector(channelsChanged)
        channelsPopUp.toolTip = "Energy alone is a sixth of the data, but has no field direction, so "
            + "combined views (such as a differential pair's) can't be shown."

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 1
        formatter.maximumFractionDigits = 0
        intervalField.formatter = formatter
        intervalField.alignment = .right
        intervalField.target = self
        intervalField.action = #selector(intervalChanged)
        intervalField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        intervalStepper.minValue = 1
        intervalStepper.maxValue = 1_000_000
        intervalStepper.increment = 100
        intervalStepper.valueWraps = false
        intervalStepper.target = self
        intervalStepper.action = #selector(stepperChanged)
        let intervalRow = NSStackView(views: [intervalField, intervalStepper, NSTextField(labelWithString: "timesteps")])
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 6

        sizeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString:
            "Applies to simulations run from now on. The first and last timesteps are always stored.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        directoryPopUp.target = self
        directoryPopUp.action = #selector(directoryChanged)
        directoryPopUp.toolTip = "In File keeps frames inside the document; a folder gets one "
            + "“<document> - <simulation>.kemsf” package per simulation."

        keepAwakeCheckbox.target = self
        keepAwakeCheckbox.action = #selector(keepAwakeChanged)
        keepAwakeCheckbox.toolTip = "Stops idle sleep and App Nap while a job is running (not while the "
            + "queue is paused). macOS doesn't let apps turn on High Power Mode or turn off Low Power "
            + "Mode, so set those in System Settings > Battery if you need them."

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Field frame precision:"), precisionPopUp],
            [NSTextField(labelWithString: "Field frame channels:"), channelsPopUp],
            [NSTextField(labelWithString: "Store a frame every:"), intervalRow],
            [NSGridCell.emptyContentView, sizeLabel],
            [NSTextField(labelWithString: "Save field frames:"), directoryPopUp],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8

        let stack = NSStackView(views: [grid, note, keepAwakeCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func reload() {
        let precision = FieldFramePreferences.precision
        precisionPopUp.selectItem(at: Self.precisions.firstIndex { $0.0 == precision } ?? Self.precisions.count - 1)
        let channels = FieldFramePreferences.channels
        channelsPopUp.selectItem(at: Self.channelChoices.firstIndex { $0.0 == channels } ?? 0)
        intervalField.integerValue = FieldFramePreferences.intervalSteps
        intervalStepper.integerValue = FieldFramePreferences.intervalSteps
        updateSizeLabel()
        keepAwakeCheckbox.state = PowerPreferences.keepAwakeWhileJobsRun ? .on : .off
        directoryPopUp.removeAllItems()
        directoryPopUp.addItem(withTitle: "In File")
        if let directory = FieldFramePreferences.directory {
            directoryPopUp.addItem(withTitle: FileManager.default.displayName(atPath: directory.path))
            directoryPopUp.lastItem?.image = NSWorkspace.shared.icon(forFile: directory.path)
            directoryPopUp.lastItem?.image?.size = NSSize(width: 16, height: 16)
            directoryPopUp.lastItem?.toolTip = directory.path
            directoryPopUp.selectItem(at: 1)
        } else {
            directoryPopUp.selectItem(at: 0)
        }
        directoryPopUp.menu?.addItem(.separator())
        directoryPopUp.addItem(withTitle: "Choose Folder…")
    }

    /// The uncompressed cost of a frame, so the trade-off between the choices is visible.
    private func updateSizeLabel() {
        let bytesPerSample = Self.precisions[precisionPopUp.indexOfSelectedItem].2
        let channels = Self.channelChoices[channelsPopUp.indexOfSelectedItem].2
        let bytes = bytesPerSample * channels
        sizeLabel.stringValue = "\(bytes) byte\(bytes == 1 ? "" : "s") per mesh cell per frame, before compression"
    }

    @objc private func precisionChanged() {
        FieldFramePreferences.precision = Self.precisions[precisionPopUp.indexOfSelectedItem].0
        updateSizeLabel()
    }

    @objc private func channelsChanged() {
        FieldFramePreferences.channels = Self.channelChoices[channelsPopUp.indexOfSelectedItem].0
        updateSizeLabel()
    }

    @objc private func intervalChanged() {
        FieldFramePreferences.intervalSteps = max(1, intervalField.integerValue)
        intervalField.integerValue = FieldFramePreferences.intervalSteps
        intervalStepper.integerValue = FieldFramePreferences.intervalSteps
    }

    @objc private func stepperChanged() {
        intervalField.integerValue = intervalStepper.integerValue
        intervalChanged()
    }

    @objc private func keepAwakeChanged() {
        PowerPreferences.keepAwakeWhileJobsRun = keepAwakeCheckbox.state == .on
    }

    @objc private func directoryChanged() {
        let index = directoryPopUp.indexOfSelectedItem
        if index == 0 {
            FieldFramePreferences.directory = nil
        } else if index == directoryPopUp.numberOfItems - 1 {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Choose"
            panel.message = "Choose where simulations save their field frames."
            if panel.runModal() == .OK, let url = panel.url {
                FieldFramePreferences.directory = url
            }
        }
        reload()
    }
}
