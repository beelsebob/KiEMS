import Cocoa

/// The Tests section of a simulation's setup, shared by SimulationPropertiesViewController and
/// SimulationSetViewController (which edits its set's template): the eye mask every eye in the
/// results is tested against, picked from a standard (EyeTestPreset) or entered by hand, along with
/// the bit rate and signal level the eye is built at. Picking a standard fills in its settings;
/// editing any of them away from the standard's switches the popup to Custom. The standards are
/// grouped into a submenu per family (USB, DRAM, ...), so the popup is a pull-down whose title shows
/// the current one -- a pop-up button can't show an item from inside a submenu as its selection.
final class EyeTestSectionView: NSStackView {
    private static let formFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    /// The simulation edited. Nil clears and disables the controls.
    var simulation: EMSSimulationBridge? {
        didSet { reload() }
    }

    /// Fired after every edit, once it's been written to `simulation`.
    var onChange: (() -> Void)?

    private let standardPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let bitRateField = NSTextField(string: "")
    private let signalLevelField = NSTextField(string: "")
    private let x1Field = NSTextField(string: "")
    private let x2Field = NSTextField(string: "")
    private let y1Field = NSTextField(string: "")
    private let y2Field = NSTextField(string: "")
    private let shapeView = EyeMaskShapeView()

    // One formatter per field: UnitSuffixValueFormatter keeps no shared state, but the volt fields
    // must parse "300 mV" independently of each other's last display.
    private let bitRateFormatter = EyeTestSectionView.bitRateFormatter()
    private let signalLevelFormatter = EyeTestSectionView.voltsFormatter()
    private let y1Formatter = EyeTestSectionView.voltsFormatter()
    private let y2Formatter = EyeTestSectionView.voltsFormatter()
    private let x1Formatter = EyeTestSectionView.unitIntervalFormatter()
    private let x2Formatter = EyeTestSectionView.unitIntervalFormatter()

    /// `row` lays out one titled control in the owning panel's own style.
    init(row: (String, NSView) -> NSView) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        standardPopup.controlSize = .small
        standardPopup.font = Self.formFont
        if let menu = standardPopup.menu {
            menu.autoenablesItems = false
            // A pull-down's first item is its title, never listed; reload() keeps it current.
            menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
            menu.addItem(standardItem(title: EyeTestPreset.title(for: .custom), standard: .custom))
            menu.addItem(.separator())
            for family in EyeTestPreset.families {
                let submenu = NSMenu(title: family)
                submenu.autoenablesItems = false
                for preset in EyeTestPreset.all where preset.family == family {
                    if preset.startsGroup && submenu.numberOfItems > 0 {
                        submenu.addItem(.separator())
                    }
                    submenu.addItem(standardItem(title: preset.menuTitle, standard: preset.standard))
                }
                let familyItem = NSMenuItem(title: family, action: nil, keyEquivalent: "")
                familyItem.submenu = submenu
                menu.addItem(familyItem)
            }
        }

        let fields: [(NSTextField, Formatter, String)] = [
            (bitRateField, bitRateFormatter, "The serial data rate the eye's PRBS pattern is sent at."),
            (signalLevelField, signalLevelFormatter,
             "The ± level the PRBS pattern is launched at -- differential for a pair -- as a driver matched to the line would."),
            (x1Field, x1Formatter, "Where the mask's keep-out region meets the threshold, from the eye's left crossing (and as far from its right one)."),
            (x2Field, x2Formatter, "Where the keep-out region reaches its full height, from the eye's left crossing. Equal to X1 for a rectangle; 0.5 UI for a diamond."),
            (y1Field, y1Formatter, "How far the keep-out region reaches above and below the threshold. Empty for no keep-out region."),
            (y2Field, y2Formatter, "How far from the threshold the signal may go at all. Empty for no limit."),
        ]
        for (field, formatter, toolTip) in fields {
            field.formatter = formatter
            field.controlSize = .small
            field.font = Self.formFont
            field.alignment = .right
            field.target = self
            field.action = #selector(fieldChanged(_:))
            field.cell?.sendsActionOnEndEditing = true
            field.toolTip = toolTip
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        y1Field.placeholderString = "None"
        y2Field.placeholderString = "None"

        let views = [
            row("Eye Mask:", standardPopup),
            row("Bit Rate:", bitRateField),
            row("Signal Level:", signalLevelField),
            shapeView,
            row("Mask X1:", x1Field),
            row("Mask X2:", x2Field),
            row("Mask Y1:", y1Field),
            row("Outer Limit Y2:", y2Field),
        ]
        for view in views {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        reload()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func reload() {
        let controls: [NSControl] = [standardPopup, bitRateField, signalLevelField, x1Field, x2Field, y1Field, y2Field]
        guard let simulation else {
            controls.forEach { $0.isEnabled = false }
            for field in [bitRateField, signalLevelField, x1Field, x2Field, y1Field, y2Field] {
                field.stringValue = ""
            }
            showStandard(.custom)
            shapeView.mask = nil
            return
        }
        controls.forEach { $0.isEnabled = true }
        showStandard(simulation.eyeMaskStandard)
        bitRateField.doubleValue = simulation.eyeBitRate
        signalLevelField.doubleValue = simulation.eyeSignalLevel
        x1Field.doubleValue = simulation.eyeMaskX1
        x2Field.doubleValue = simulation.eyeMaskX2
        // Zero means "none" for both -- shown as the placeholder rather than as 0 V.
        y1Field.objectValue = simulation.eyeMaskY1 > 0 ? NSNumber(value: simulation.eyeMaskY1) : nil
        y2Field.objectValue = simulation.eyeMaskY2 > 0 ? NSNumber(value: simulation.eyeMaskY2) : nil
        shapeView.mask = (simulation.eyeMaskX1, simulation.eyeMaskX2, simulation.eyeMaskY1, simulation.eyeMaskY2)
    }

    private func standardItem(title: String, standard: EMSEyeMaskStandard) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(standardPicked(_:)), keyEquivalent: "")
        item.target = self
        item.tag = standard.rawValue
        return item
    }

    /// Titles the pull-down with `standard` and checks it in the menu, its family marked with a dash.
    private func showStandard(_ standard: EMSEyeMaskStandard) {
        guard let menu = standardPopup.menu, menu.numberOfItems > 0 else { return }
        menu.item(at: 0)?.title = EyeTestPreset.title(for: standard)
        for item in menu.items.dropFirst() {
            if let submenu = item.submenu {
                var containsStandard = false
                for leaf in submenu.items {
                    leaf.state = leaf.tag == standard.rawValue ? .on : .off
                    containsStandard = containsStandard || leaf.state == .on
                }
                item.state = containsStandard ? .mixed : .off
            } else if !item.isSeparatorItem {
                item.state = item.tag == standard.rawValue ? .on : .off
            }
        }
        // The pull-down's title only redraws from its first item when told to.
        standardPopup.synchronizeTitleAndSelectedItem()
    }

    @objc private func standardPicked(_ sender: NSMenuItem) {
        guard let simulation,
              let standard = EMSEyeMaskStandard(rawValue: sender.tag),
              standard != simulation.eyeMaskStandard else { return }
        if let preset = EyeTestPreset.preset(for: standard) {
            preset.apply(to: simulation)
        } else {
            // Custom keeps whatever numbers are there, now free to edit.
            simulation.eyeMaskStandard = .custom
        }
        reload()
        onChange?()
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        guard let simulation else { return }
        let value = (sender.objectValue as? NSNumber)?.doubleValue ?? 0
        let changed: Bool
        switch sender {
        case bitRateField:
            changed = value > 0 && value != simulation.eyeBitRate
            if changed { simulation.eyeBitRate = value }
        case signalLevelField:
            changed = value > 0 && value != simulation.eyeSignalLevel
            if changed { simulation.eyeSignalLevel = value }
        case x1Field:
            let clamped = min(max(value, 0), 0.5)
            changed = clamped != simulation.eyeMaskX1
            if changed { simulation.eyeMaskX1 = clamped }
        case x2Field:
            let clamped = min(max(value, 0), 0.5)
            changed = clamped != simulation.eyeMaskX2
            if changed { simulation.eyeMaskX2 = clamped }
        case y1Field:
            changed = max(value, 0) != simulation.eyeMaskY1
            if changed { simulation.eyeMaskY1 = max(value, 0) }
        case y2Field:
            changed = max(value, 0) != simulation.eyeMaskY2
            if changed { simulation.eyeMaskY2 = max(value, 0) }
        default:
            changed = false
        }
        guard changed else {
            // Puts back what's in effect: a rejected value (a zero bit rate, say), or the same value
            // re-shown in its canonical form.
            reload()
            return
        }
        if let preset = EyeTestPreset.preset(for: simulation.eyeMaskStandard), !preset.matches(simulation) {
            simulation.eyeMaskStandard = .custom
        }
        reload()
        onChange?()
    }

    // MARK: - Formatters

    static func bitRateFormatter() -> UnitSuffixValueFormatter {
        UnitSuffixValueFormatter(
            displaySuffix: "bit/s", acceptedSuffixes: ["bit/s", "bps"],
            scaledSuffixes: SIPrefix.allCases.flatMap { prefix in
                prefix.inputSymbols.flatMap { symbol in
                    [
                        (suffix: "\(symbol)b/s", factor: prefix.factor),
                        (suffix: "\(symbol)B/s", factor: 8 * prefix.factor),
                    ]
                }
            },
            autoSelectsSIPrefix: true)
    }

    private static func voltsFormatter() -> UnitSuffixValueFormatter {
        UnitSuffixValueFormatter(displaySuffix: "V", acceptedSuffixes: ["volts", "volt", "v"], autoSelectsSIPrefix: true)
    }

    private static func unitIntervalFormatter() -> UnitSuffixValueFormatter {
        UnitSuffixValueFormatter(displaySuffix: "UI", acceptedSuffixes: ["ui"])
    }
}

/// A small sketch of the mask EyeTestSectionView is editing, labelled with the parameters that
/// shape it, so X1/X2/Y1/Y2 read as positions rather than bare numbers.
private final class EyeMaskShapeView: NSView {
    /// (x1, x2, y1, y2) as EMSSimulationBridge holds them; nil draws nothing.
    var mask: (x1: Double, x2: Double, y1: Double, y2: Double)? {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 72) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let mask else { return }
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let hasKeepOut = mask.y1 > 0 && mask.x1 < 0.5
        let hasLimit = mask.y2 > 0
        guard hasKeepOut || hasLimit else {
            let text = "No mask: eyes aren't tested." as NSString
            let size = text.size(withAttributes: labelAttributes)
            text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                      withAttributes: labelAttributes)
            return
        }

        // The unit interval with a little room either side; the threshold through the middle.
        let plot = bounds.insetBy(dx: 22, dy: 6)
        let yExtent = max(hasLimit ? mask.y2 * 1.2 : 0, hasKeepOut ? mask.y1 * 1.6 : 0)
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((x + 0.1) / 1.2) * plot.width,
                    y: plot.midY + CGFloat(y / yExtent) * plot.height / 2)
        }

        NSColor.separatorColor.setStroke()
        let threshold = NSBezierPath()
        threshold.move(to: point(-0.1, 0))
        threshold.line(to: point(1.1, 0))
        threshold.setLineDash([3, 2], count: 2, phase: 0)
        threshold.lineWidth = 0.5
        threshold.stroke()
        for x in [0.0, 1.0] {
            let crossing = NSBezierPath()
            crossing.move(to: CGPoint(x: point(x, 0).x, y: plot.minY))
            crossing.line(to: CGPoint(x: point(x, 0).x, y: plot.maxY))
            crossing.lineWidth = 0.5
            crossing.stroke()
        }

        let fill = NSColor.systemRed.withAlphaComponent(0.18)
        let stroke = NSColor.systemRed.withAlphaComponent(0.8)
        if hasLimit {
            for sign in [1.0, -1.0] {
                let edge = point(0, sign * mask.y2).y
                let band = sign > 0 ? NSRect(x: plot.minX, y: edge, width: plot.width, height: plot.maxY - edge)
                                    : NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: edge - plot.minY)
                fill.setFill()
                band.fill()
                stroke.setStroke()
                let line = NSBezierPath()
                line.move(to: CGPoint(x: plot.minX, y: edge))
                line.line(to: CGPoint(x: plot.maxX, y: edge))
                line.lineWidth = 1
                line.stroke()
            }
            ("Y2" as NSString).draw(at: CGPoint(x: plot.minX - 16, y: point(0, mask.y2).y - 6),
                                    withAttributes: labelAttributes)
        }
        if hasKeepOut {
            // Clamped the way kiems::EyeMask's tester clamps it.
            let x1 = max(mask.x1, 0)
            let x2 = min(max(mask.x2, x1), 0.5)
            let hexagon = NSBezierPath()
            hexagon.move(to: point(x1, 0))
            hexagon.line(to: point(x2, -mask.y1))
            hexagon.line(to: point(1 - x2, -mask.y1))
            hexagon.line(to: point(1 - x1, 0))
            hexagon.line(to: point(1 - x2, mask.y1))
            hexagon.line(to: point(x2, mask.y1))
            hexagon.close()
            fill.setFill()
            hexagon.fill()
            stroke.setStroke()
            hexagon.lineWidth = 1
            hexagon.stroke()
            let x1Label = "X1" as NSString
            let x1Size = x1Label.size(withAttributes: labelAttributes)
            x1Label.draw(at: CGPoint(x: point(x1, 0).x - x1Size.width - 2, y: point(x1, 0).y - x1Size.height / 2),
                         withAttributes: labelAttributes)
            ("X2" as NSString).draw(at: CGPoint(x: point(x2, mask.y1).x - 6, y: point(x2, mask.y1).y + 1),
                                    withAttributes: labelAttributes)
            ("Y1" as NSString).draw(at: CGPoint(x: plot.minX - 16, y: point(0, mask.y1).y - 6),
                                    withAttributes: labelAttributes)
        }
    }
}
