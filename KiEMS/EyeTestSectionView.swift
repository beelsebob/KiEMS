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

    /// This intentionally has more vertical breathing room than the old inline sketch: it appears
    /// in narrow inspector panels, where labels drawn directly beside the shape became illegible.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 170) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard mask != nil else { return }
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.88),
        ]
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        // This is a key for the fields below, not a thumbnail of their current values.  Keep the
        // example deliberately sloped so the distinct meanings of X1 and X2 remain visible even
        // when the selected mask happens to be rectangular.
        let diagram = (x1: 0.18, x2: 0.32, y1: 0.44, y2: 0.74)

        // The dimensions attach directly to the feature they describe.  This is deliberately a
        // technical drawing rather than a legend: the values below it are the authoritative ones.
        ("Eye mask profile" as NSString).draw(at: CGPoint(x: 0, y: bounds.maxY - 14), withAttributes: titleAttributes)
        // A generous left gutter is reserved for the vertical dimensions; keeping the entire
        // construction below the heading lets X2 sit above its own measurement line.
        let plot = NSRect(x: 60, y: 40, width: max(bounds.width - 66, 1), height: 80)
        let yExtent = diagram.y2 * 1.2
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((x + 0.1) / 1.2) * plot.width,
                    y: plot.midY + CGFloat(y / yExtent) * plot.height / 2)
        }

        let guideColor = NSColor.labelColor.withAlphaComponent(0.34)
        guideColor.setStroke()
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

        // Name the fixed reference points, with sufficiently strong contrast to remain readable
        // in the dark inspector appearance.
        let crossingAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.7),
        ]
        ("Decision threshold" as NSString).draw(at: CGPoint(x: plot.maxX - 76, y: plot.midY + 4),
                                        withAttributes: crossingAttributes)

        let keepOutFill = NSColor.systemRed.withAlphaComponent(0.34)
        let keepOutStroke = NSColor.systemRed
        let limitFill = NSColor.systemOrange.withAlphaComponent(0.28)
        let limitStroke = NSColor.systemOrange
        let constructionStroke = NSColor.labelColor.withAlphaComponent(0.9)
        for sign in [1.0, -1.0] {
            let edge = point(0, sign * diagram.y2).y
            let band = sign > 0 ? NSRect(x: plot.minX, y: edge, width: plot.width, height: plot.maxY - edge)
                                : NSRect(x: plot.minX, y: plot.minY, width: plot.width, height: edge - plot.minY)
            limitFill.setFill()
            band.fill()
            limitStroke.setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: edge))
            line.line(to: CGPoint(x: plot.maxX, y: edge))
            line.lineWidth = 1.5
            line.stroke()
        }
        let y2 = point(0, diagram.y2).y
        let y2DimensionX = plot.minX - 27
        let y2Dimension = NSBezierPath()
        y2Dimension.move(to: CGPoint(x: y2DimensionX, y: plot.midY))
        y2Dimension.line(to: CGPoint(x: y2DimensionX, y: y2))
        y2Dimension.move(to: CGPoint(x: y2DimensionX - 3, y: plot.midY))
        y2Dimension.line(to: CGPoint(x: y2DimensionX + 3, y: plot.midY))
        y2Dimension.move(to: CGPoint(x: y2DimensionX - 3, y: y2))
        y2Dimension.line(to: CGPoint(x: y2DimensionX + 3, y: y2))
        limitStroke.setStroke()
        y2Dimension.lineWidth = 1.5
        y2Dimension.stroke()
        let y2Label = "Y2" as NSString
        let y2LabelSize = y2Label.size(withAttributes: labelAttributes)
        y2Label.draw(at: CGPoint(x: y2DimensionX - y2LabelSize.width - 4, y: (plot.midY + y2) / 2 - 6),
                     withAttributes: labelAttributes)
        let y2Projection = NSBezierPath()
        y2Projection.move(to: CGPoint(x: y2DimensionX, y: y2))
        y2Projection.line(to: CGPoint(x: plot.minX, y: y2))
        y2Projection.setLineDash([3, 3], count: 2, phase: 0)
        limitStroke.setStroke()
        y2Projection.lineWidth = 1
        y2Projection.stroke()
        do {
            let x1 = diagram.x1
            let x2 = diagram.x2
            let hexagon = NSBezierPath()
            hexagon.move(to: point(x1, 0))
            hexagon.line(to: point(x2, -diagram.y1))
            hexagon.line(to: point(1 - x2, -diagram.y1))
            hexagon.line(to: point(1 - x1, 0))
            hexagon.line(to: point(1 - x2, diagram.y1))
            hexagon.line(to: point(x2, diagram.y1))
            hexagon.close()
            keepOutFill.setFill()
            hexagon.fill()
            keepOutStroke.setStroke()
            hexagon.lineWidth = 1.5
            hexagon.stroke()
            let leftCrossing = point(0, 0)
            let x1Point = point(x1, 0)
            let dimensionY = plot.minY - 8
            let dimension = NSBezierPath()
            dimension.move(to: CGPoint(x: leftCrossing.x, y: dimensionY))
            dimension.line(to: CGPoint(x: x1Point.x, y: dimensionY))
            dimension.move(to: CGPoint(x: leftCrossing.x, y: dimensionY - 3))
            dimension.line(to: CGPoint(x: leftCrossing.x, y: dimensionY + 3))
            dimension.move(to: CGPoint(x: x1Point.x, y: dimensionY - 3))
            dimension.line(to: CGPoint(x: x1Point.x, y: dimensionY + 3))
            keepOutStroke.setStroke()
            dimension.lineWidth = 1.5
            dimension.stroke()
            let x1Projection = NSBezierPath()
            x1Projection.move(to: CGPoint(x: x1Point.x, y: dimensionY))
            x1Projection.line(to: x1Point)
            x1Projection.setLineDash([3, 3], count: 2, phase: 0)
            keepOutStroke.setStroke()
            x1Projection.lineWidth = 1
            x1Projection.stroke()
            let xLabelString = "X1" as NSString
            let xLabelSize = xLabelString.size(withAttributes: labelAttributes)
            xLabelString.draw(at: CGPoint(x: (leftCrossing.x + x1Point.x - xLabelSize.width) / 2,
                                           y: dimensionY - 17), withAttributes: labelAttributes)

            // X2 measures from the same left crossing to the point at which the sloped edge
            // reaches its full height.  Giving it a parallel dimension line makes that horizontal
            // relationship unambiguous, including for a rectangular mask where X1 equals X2.
            let x2Corner = point(x2, diagram.y1)
            let x2DimensionY = plot.maxY + 8
            let x2Dimension = NSBezierPath()
            x2Dimension.move(to: leftCrossing)
            x2Dimension.line(to: CGPoint(x: leftCrossing.x, y: x2DimensionY))
            x2Dimension.move(to: CGPoint(x: leftCrossing.x, y: x2DimensionY))
            x2Dimension.line(to: CGPoint(x: x2Corner.x, y: x2DimensionY))
            x2Dimension.move(to: CGPoint(x: leftCrossing.x, y: x2DimensionY - 3))
            x2Dimension.line(to: CGPoint(x: leftCrossing.x, y: x2DimensionY + 3))
            x2Dimension.move(to: CGPoint(x: x2Corner.x, y: x2DimensionY - 3))
            x2Dimension.line(to: CGPoint(x: x2Corner.x, y: x2DimensionY + 3))
            x2Dimension.lineWidth = 1.5
            x2Dimension.stroke()
            let x2Projection = NSBezierPath()
            x2Projection.move(to: CGPoint(x: x2Corner.x, y: x2DimensionY))
            x2Projection.line(to: x2Corner)
            x2Projection.setLineDash([3, 3], count: 2, phase: 0)
            constructionStroke.setStroke()
            x2Projection.lineWidth = 1
            x2Projection.stroke()
            let x2Label = "X2" as NSString
            let x2LabelSize = x2Label.size(withAttributes: labelAttributes)
            x2Label.draw(at: CGPoint(x: (leftCrossing.x + x2Corner.x - x2LabelSize.width) / 2,
                                     y: x2DimensionY + 4), withAttributes: labelAttributes)

            let y1 = point(0, diagram.y1).y
            let dimensionX = plot.minX - 13
            let yDimension = NSBezierPath()
            yDimension.move(to: CGPoint(x: dimensionX, y: plot.midY))
            yDimension.line(to: CGPoint(x: dimensionX, y: y1))
            yDimension.move(to: CGPoint(x: dimensionX - 3, y: plot.midY))
            yDimension.line(to: CGPoint(x: dimensionX + 3, y: plot.midY))
            yDimension.move(to: CGPoint(x: dimensionX - 3, y: y1))
            yDimension.line(to: CGPoint(x: dimensionX + 3, y: y1))
            yDimension.lineWidth = 1.5
            yDimension.stroke()
            let y1Projection = NSBezierPath()
            y1Projection.move(to: CGPoint(x: dimensionX, y: y1))
            y1Projection.line(to: CGPoint(x: x2Corner.x, y: y1))
            y1Projection.setLineDash([3, 3], count: 2, phase: 0)
            constructionStroke.setStroke()
            y1Projection.lineWidth = 1
            y1Projection.stroke()
            ("Y1" as NSString).draw(at: CGPoint(x: dimensionX + 4, y: (plot.midY + y1) / 2 - 6),
                                      withAttributes: labelAttributes)
        }
    }
}
