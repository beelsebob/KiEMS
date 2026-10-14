import Cocoa

/// File > Save Report's PDF: a summary page listing every simulation's test verdict, followed by
/// each simulation's detail pages -- its eye diagrams (with their masks) and then every other
/// chart its results tab shows, built by the same SimulationResultsViewController.sections code.
///
/// Each heading, note and chart is laid out on its own as an offscreen view at the page's content
/// width and rendered to vector PDF, then those blocks are stacked onto Letter-sized pages, a new
/// page starting whenever the next block doesn't fit (one taller than a whole page is scaled down).
enum ResultsReport {
    enum Verdict {
        case pass, fail, warning, notRun

        var title: String {
            switch self {
            case .pass: return "PASS"
            case .fail: return "FAIL"
            case .warning: return "WARNING"
            case .notRun: return "NOT RUN"
            }
        }

        var color: NSColor {
            switch self {
            case .pass: return ResultsReport.passGreen
            case .fail: return ResultsReport.failRed
            case .warning: return .systemOrange
            case .notRun: return .systemGray
            }
        }

        /// The same symbols the results views use for a passed or failed eye mask.
        var symbolName: String {
            switch self {
            case .pass: return "checkmark.circle.fill"
            case .fail: return "exclamationmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .notRun: return "circle.dashed"
            }
        }
    }

    /// A darker green than .systemGreen, which is too light to read on a printed page.
    static let passGreen = NSColor(srgbRed: 0x1b / 255, green: 0x7a / 255, blue: 0x34 / 255, alpha: 1)
    /// Likewise a darker red than .systemRed, to match passGreen.
    static let failRed = NSColor(srgbRed: 0xb3 / 255, green: 0x26 / 255, blue: 0x1e / 255, alpha: 1)

    /// The fill of a warning's black-outlined triangle.
    private static let warningSignAmber = NSColor(srgbRed: 1, green: 0xc0 / 255, blue: 0, alpha: 1)

    /// One simulation's line on the summary page and its detail pages.
    struct Entry {
        var name: String
        /// The Simulation Set that generated it, if any.
        var setName: String?
        var verdict: Verdict
        /// Why the verdict is what it is, one finding per line.
        var notes: [String]
        /// The charts to show, grouped under their results-tab category; empty without results.
        var categories: [(title: String, sections: [ResultsSection])]
    }

    /// A line of the summary page: a lone simulation's verdict and notes, or a Simulation Set's
    /// heading over a grid of its generated simulations' verdicts.
    enum SummaryItem {
        case simulation(Entry)
        case set(name: String, members: [(name: String, verdict: Verdict)])
    }

    /// The verdict for a simulation with `preview` as its results (nil if it has none), the reasons
    /// they're out of date, and its pipeline's warnings: FAIL when an eye leaves its mask or the run
    /// failed; NOT RUN without results; WARNING when there's nothing to judge against, or the result
    /// can't be fully trusted; PASS otherwise.
    static func verdict(preview: EMSResultsPreview?, runError: String?, staleReasons: [String],
                        pipelineWarnings: [String]) -> (Verdict, [String]) {
        guard let preview else {
            if let runError { return (.fail, ["Simulation failed: \(runError)"]) }
            return (.notRun, ["Simulation has not been run."])
        }
        var failures: [String] = []
        var warnings: [String] = []
        let maskedEyes = preview.eyeDiagrams.filter { $0.mask != nil }
        if preview.eyeDiagrams.isEmpty {
            warnings.append("No eye diagrams to test.")
        } else if maskedEyes.isEmpty {
            warnings.append("No eye mask is set, so the eyes aren't tested.")
        }
        for eye in maskedEyes {
            if eye.failsMask {
                let noiseFreeFails = eye.maskResult.map { !$0.passed } ?? false
                let noisyFails = eye.noise?.maskResult.map { !$0.passed } ?? false
                let modes = [noiseFreeFails ? "noise-free" : nil, noisyFails ? "with adversarial signals" : nil]
                    .compactMap { $0 }.joined(separator: " and ")
                failures.append("\(eye.name) leaves the eye mask" + (modes.isEmpty ? "." : " (\(modes))."))
            } else {
                warnings += eye.noise.flatMap { unstableNote(eye: eye, noise: $0) }.map { [$0] } ?? []
            }
        }
        if !staleReasons.isEmpty {
            warnings.append("Results are out of date: " + staleReasons.joined(separator: "; ") + ".")
        }
        warnings += pipelineWarnings
        if !failures.isEmpty {
            return (.fail, failures + warnings)
        }
        if !warnings.isEmpty {
            return (.warning, warnings)
        }
        return (.pass, maskedEyes.map { "\($0.name) passes the eye mask." })
    }

    /// Matches AdversarialEyeView's stability judgement: replicates must agree to within 5% of the
    /// noise-free opening.
    private static func unstableNote(eye: EMSResultsEyeDiagram, noise: EMSResultsEyeNoise) -> String? {
        let heightReference = max(eye.heightV, abs(noise.heightV), .ulpOfOne)
        let widthReference = max(eye.widthUI, noise.widthUI, .ulpOfOne)
        let stable = noise.highestHeightV - noise.lowestHeightV <= 0.05 * heightReference &&
            noise.highestWidthUI - noise.lowestWidthUI <= 0.05 * widthReference
        return stable ? nil : "\(eye.name)'s adversarial result isn't yet stable; increase Adversarial Draws."
    }

    // MARK: - Rendering

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 40
    private static var contentWidth: CGFloat { pageSize.width - 2 * margin }
    private static var contentHeight: CGFloat { pageSize.height - 2 * margin }

    /// One rendered piece of a page.
    private struct Block {
        var page: CGPDFPage
        var size: CGSize
        /// Space left above it when it isn't the first block on its page.
        var spacingBefore: CGFloat
        /// Starts a new page even if it would fit on the current one.
        var startsPage = false
        /// The PDF destination named at its top, which `links` elsewhere jump to.
        var destination: String?
        /// Clickable areas, in the block's top-down coordinates, and the destinations they go to.
        var links: [(rect: CGRect, destination: String)] = []
    }

    /// The PDF destination of `name`'s detail pages.
    private static func destination(forSimulationNamed name: String) -> String {
        "simulation:" + name
    }

    /// `summary` lists the summary page's lines in document order; `entries` every simulation that
    /// gets detail pages.
    /// Without `includeTestResults` there's no summary page and no verdicts or notes, and a
    /// simulation with no charts left gets no pages at all.
    static func pdfData(title: String, summary: [SummaryItem], entries: [Entry],
                        includeTestResults: Bool = true) -> Data {
        var blocks: [Block] = []
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            if includeTestResults {
                blocks.append(contentsOf: summaryBlocks(title: title, summary: summary, entries: entries))
            }
            for entry in entries where includeTestResults || !entry.categories.isEmpty {
                blocks.append(contentsOf: detailBlocks(for: entry, includeTestResults: includeTestResults))
            }
        }

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                      [kCGPDFContextTitle: title, kCGPDFContextCreator: "KiEMS"] as CFDictionary)
        else { return Data() }

        var y: CGFloat = 0   // Distance down from the top of the content area.
        var pageOpen = false
        func newPage() {
            if pageOpen { context.endPDFPage() }
            context.beginPDFPage(nil)
            pageOpen = true
            y = 0
        }
        for block in blocks {
            let scale = min(1, contentHeight / block.size.height, contentWidth / block.size.width)
            let height = block.size.height * scale
            let spacing = y > 0 ? block.spacingBefore : 0
            if !pageOpen || block.startsPage || y + spacing + height > contentHeight {
                newPage()
            } else {
                y += spacing
            }
            context.saveGState()
            context.translateBy(x: margin, y: pageSize.height - margin - y - height)
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(block.page)
            context.restoreGState()
            let top = pageSize.height - margin - y
            if let destination = block.destination {
                context.addDestination(destination as CFString, at: CGPoint(x: margin, y: top))
            }
            for link in block.links {
                let rect = CGRect(x: margin + link.rect.minX * scale, y: top - link.rect.maxY * scale,
                                  width: link.rect.width * scale, height: link.rect.height * scale)
                context.setDestination(link.destination as CFString, for: rect)
            }
            y += height
        }
        if pageOpen { context.endPDFPage() }
        context.closePDF()
        return data as Data
    }

    private static func summaryBlocks(title: String, summary: [SummaryItem], entries: [Entry]) -> [Block] {
        var blocks: [Block] = []
        let titleLabel = label(title, font: .systemFont(ofSize: 22, weight: .bold))
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
        let subtitle = label("Simulation test report — \(date)", font: .systemFont(ofSize: 11),
                             color: .secondaryLabelColor)
        blocks += [render(stack([titleLabel, subtitle], spacing: 4), spacingBefore: 0)]

        let counts = [Verdict.pass, .warning, .fail, .notRun].map { verdict in
            "\(entries.filter { $0.verdict == verdict }.count) \(verdict.title.lowercased())"
        }
        let tests = entries.count == 1 ? "1 test" : "\(entries.count) tests"
        blocks += [render(label("\(tests): " + counts.joined(separator: ", "),
                                font: .systemFont(ofSize: 12, weight: .medium)), spacingBefore: 14)]
        for item in summary {
            switch item {
            case .simulation(let entry):
                let row = summaryRow(for: entry)
                blocks.append(render(row.view, spacingBefore: 10,
                                     links: [(row.badge, destination(forSimulationNamed: entry.name))]))
            case .set(let name, let members):
                blocks += setBlocks(name: name, members: members)
            }
        }
        if entries.isEmpty {
            blocks.append(render(label("This document has no simulations.", font: .systemFont(ofSize: 12)),
                                 spacingBefore: 10))
        }
        return blocks
    }

    private static func summaryRow(for entry: Entry) -> (view: NSView, badge: NSView) {
        let name = NetNameView()
        name.configure(name: entry.name, font: .systemFont(ofSize: 13, weight: .semibold))
        let notes = entry.notes.map { note in
            wrappingLabel(note, font: .systemFont(ofSize: 10), color: .secondaryLabelColor,
                          width: contentWidth - 110)
        }
        let text = stack([name] + notes, spacing: 2)
        let verdictBadge = badge(entry.verdict)
        let row = NSStackView(views: [verdictBadge, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return (row, verdictBadge)
    }

    /// A Simulation Set's heading, then its members' verdict symbols in rows, each under its name
    /// with the part every member shares (e.g. "DDR_A" of DDR_A0...DDR_A15) left off.
    private static func setBlocks(name: String, members: [(name: String, verdict: Verdict)]) -> [Block] {
        let heading = NetNameView()
        heading.configure(name: name, font: .systemFont(ofSize: 15, weight: .bold))
        guard !members.isEmpty else {
            let empty = label("No simulations generated.", font: .systemFont(ofSize: 10),
                              color: .secondaryLabelColor)
            return [render(stack([heading, empty], spacing: 6), spacingBefore: 18)]
        }
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let labels = memberLabels(members.map(\.name))
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0
        let cellWidth = max(22, ceil(widest) + 6)
        let perRow = max(1, Int((contentWidth + 2) / (cellWidth + 2)))
        let cells = zip(labels, members).map { label, member -> NSView in
            let text = NSTextField(labelWithString: label)
            text.font = labelFont
            text.textColor = .secondaryLabelColor
            text.alignment = .center
            text.lineBreakMode = .byTruncatingMiddle
            let icon = NSImageView()
            icon.image = verdictIcon(member.verdict)
            let cell = NSStackView(views: [text, icon])
            cell.orientation = .vertical
            cell.alignment = .centerX
            cell.spacing = 2
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.widthAnchor.constraint(equalToConstant: cellWidth).isActive = true
            text.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            return cell
        }
        // Each cell links to its simulation's detail pages.
        let links = zip(cells, members).map { cell, member in
            (view: cell, destination: destination(forSimulationNamed: member.name))
        }
        return stride(from: 0, to: cells.count, by: perRow).map { start -> Block in
            let range = start..<min(start + perRow, cells.count)
            let row = NSStackView(views: Array(cells[range]))
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 2
            // The heading travels with the first row so it never ends a page.
            return start == 0
                ? render(stack([heading, row], spacing: 6), spacingBefore: 18, links: Array(links[range]))
                : render(row, spacingBefore: 6, links: Array(links[range]))
        }
    }

    /// `names` with their common prefix and suffix removed, or whole if that would leave any empty.
    private static func memberLabels(_ names: [String]) -> [String] {
        guard names.count > 1 else { return names }
        func common(_ a: [Character], _ b: [Character]) -> Int {
            zip(a, b).prefix { $0 == $1 }.count
        }
        let chars = names.map(Array.init)
        let prefix = chars.dropFirst().reduce(chars[0].count) { min($0, common(chars[0], $1)) }
        let reversed = chars.map { Array($0.reversed()) }
        let suffix = reversed.dropFirst().reduce(reversed[0].count) { min($0, common(reversed[0], $1)) }
        let trimmed = chars.map { name -> String in
            let end = max(prefix, name.count - suffix)
            return String(name[prefix..<end])
        }
        return trimmed.contains(where: \.isEmpty) ? names : trimmed
    }

    /// The verdict's symbol in its colour. A warning's orange is too light to stand out on a
    /// printed page by itself, so its triangle also gets a black outline (and "!").
    private static func verdictIcon(_ verdict: Verdict) -> NSImage? {
        func symbol(_ name: String, _ color: NSColor) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: verdict.title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                    .applying(.init(paletteColors: [color])))
        }
        // A warning's triangle is amber, like a road sign, which its outline keeps legible; the
        // badge's WARNING text stays the darker orange.
        let fill = verdict == .warning ? warningSignAmber : verdict.color
        guard let filled = symbol(verdict.symbolName, fill) else { return nil }
        guard verdict == .warning, let outline = symbol("exclamationmark.triangle", .black) else { return filled }
        let size = CGSize(width: max(filled.size.width, outline.size.width),
                          height: max(filled.size.height, outline.size.height))
        let image = NSImage(size: size, flipped: false) { bounds in
            for layer in [filled, outline] {
                layer.draw(in: CGRect(x: bounds.midX - layer.size.width / 2, y: bounds.midY - layer.size.height / 2,
                                      width: layer.size.width, height: layer.size.height))
            }
            return true
        }
        // Keep the symbol's alignment rect so image views place it on the same baseline as the
        // other verdicts' plain symbols rather than by its bounds.
        image.alignmentRect = filled.alignmentRect.offsetBy(dx: (size.width - filled.size.width) / 2,
                                                            dy: (size.height - filled.size.height) / 2)
        image.accessibilityDescription = verdict.title
        return image
    }

    /// The verdict's symbol and word in its colour, at a fixed width so the names line up.
    private static func badge(_ verdict: Verdict) -> NSView {
        let icon = NSImageView()
        icon.image = verdictIcon(verdict)
        let word = label(verdict.title, font: .systemFont(ofSize: 12, weight: .bold), color: verdict.color)
        let badge = NSStackView(views: [icon, word])
        badge.orientation = .horizontal
        badge.alignment = .centerY
        badge.spacing = 4
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 98).isActive = true
        return badge
    }

    private static func detailBlocks(for entry: Entry, includeTestResults: Bool) -> [Block] {
        // Each simulation's sheet starts a page under a heading big enough to find it by flicking
        // through: its set (or just "Simulation") above its name, then its verdict.
        let kind = NetNameView()
        kind.configure(name: entry.setName.map { "Simulation Set: \($0)" } ?? "Simulation",
                       font: .systemFont(ofSize: 16, weight: .semibold), color: .secondaryLabelColor)
        let name = NetNameView()
        name.configure(name: entry.name, font: .systemFont(ofSize: 36, weight: .bold))
        let header = NSStackView(views: includeTestResults ? [kind, name, badge(entry.verdict)] : [kind, name])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.setCustomSpacing(10, after: name)
        var heading = render(header, spacingBefore: 0)
        heading.startsPage = true
        heading.destination = destination(forSimulationNamed: entry.name)
        var blocks = [heading]
        blocks += (includeTestResults ? entry.notes : []).map { note in
            render(wrappingLabel(note, font: .systemFont(ofSize: 11), color: .secondaryLabelColor,
                                 width: contentWidth), spacingBefore: 4)
        }
        for category in entry.categories {
            let categoryLabel = label(category.title, font: .systemFont(ofSize: 15, weight: .semibold))
            var pendingCategory = PendingView(view: categoryLabel)
            for section in category.sections {
                let sectionTitle = NetNameView()
                sectionTitle.configure(name: section.title, font: .systemFont(ofSize: 12, weight: .semibold))
                let graphs = (section.graphs + section.collapsedGraphs).map { graph -> NSView in
                    let graphTitle = label(graph.title, font: .systemFont(ofSize: 10, weight: .medium),
                                           color: .secondaryLabelColor)
                    return stack([graphTitle, graph.view], spacing: 4)
                }
                // The category heading travels with its first section's first chart, and each
                // section's heading with its own first chart, so no heading ends a page.
                for (index, graph) in graphs.enumerated() {
                    var views: [NSView] = []
                    if let pending = pendingCategory.take() { views.append(pending) }
                    if index == 0 { views.append(sectionTitle) }
                    views.append(graph)
                    let spacing: CGFloat = views.count > 2 ? 22 : index == 0 ? 16 : 10
                    blocks.append(render(stack(views, spacing: 6), spacingBefore: spacing))
                }
            }
            if let pending = pendingCategory.take() {
                blocks.append(render(pending, spacingBefore: 22))
            }
        }
        return blocks
    }

    // MARK: - Views

    private static func label(_ string: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = color
        return label
    }

    private static func wrappingLabel(_ string: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = font
        label.textColor = color
        label.preferredMaxLayoutWidth = width
        return label
    }

    private static func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views where view is NSStackView || !(view is NSTextField || view is NetNameView) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Lays `view` out at the content width and renders it to a one-page PDF block.
    /// Each of `links`' views, which must be inside `view`, becomes a link to its destination.
    private static func render(_ view: NSView, spacingBefore: CGFloat,
                               links: [(view: NSView, destination: String)] = []) -> Block {
        let container = ReportBlockView(frame: CGRect(x: 0, y: 0, width: contentWidth, height: 10))
        container.appearance = NSAppearance(named: .aqua)
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        // Repeated until it settles: some views set a height (SmithChartView) or a label's wrap
        // width (AdversarialEyeView) from their own width in layout(), which only takes effect on
        // the following pass.
        var height: CGFloat = 0
        for _ in 0..<5 {
            container.layoutSubtreeIfNeeded()
            invalidateWrappingLabels(in: container)
            container.layoutSubtreeIfNeeded()
            let fitting = max(ceil(view.fittingSize.height), 1)
            if fitting == height { break }
            height = fitting
            container.setFrameSize(CGSize(width: contentWidth, height: height))
        }
        container.layoutSubtreeIfNeeded()
        // Drawn into a plain PDF context rather than with dataWithPDF(inside:), which goes through
        // the print path: that lays text out with printer font metrics, wider than the screen
        // metrics the labels were sized with, so text clipped at its frame's edge.
        let data = NSMutableData()
        var box = container.bounds
        if let consumer = CGDataConsumer(data: data),
           let context = CGContext(consumer: consumer, mediaBox: &box, nil) {
            context.beginPDFPage(nil)
            container.displayIgnoringOpacity(container.bounds,
                                             in: NSGraphicsContext(cgContext: context, flipped: false))
            context.endPDFPage()
            context.closePDF()
        }
        let page = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)?.page(at: 1)
        return Block(page: page ?? emptyPage, size: container.bounds.size, spacingBefore: spacingBefore,
                     links: links.map { ($0.view.convert($0.view.bounds, to: container), $0.destination) })
    }

    /// Offscreen layout has a 1x backing scale, so a wrapping label sized to fit its text on one
    /// line can be rounded down a fraction of a point, wrap, and clip its second line. Each pass
    /// re-measures the labels and keeps any that fit on one line at least that (rounded up) wide.
    private static func invalidateWrappingLabels(in view: NSView) {
        if let label = view as? NSTextField, label.cell?.wraps == true {
            label.invalidateIntrinsicContentSize()
            let width = ceil(label.intrinsicContentSize.width) + 1
            let identifier = "ResultsReport.minimumLabelWidth"
            if let superview = label.superview, width <= superview.bounds.width,
               label.preferredMaxLayoutWidth == 0 || width <= label.preferredMaxLayoutWidth + 1 {
                let existing = label.constraints.first { $0.identifier == identifier }
                if let existing {
                    existing.constant = width
                } else {
                    let constraint = label.widthAnchor.constraint(greaterThanOrEqualToConstant: width)
                    constraint.identifier = identifier
                    constraint.priority = .defaultHigh
                    constraint.isActive = true
                }
            }
        }
        view.subviews.forEach(invalidateWrappingLabels)
    }

    private static let emptyPage: CGPDFPage = {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 1, height: 1)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return CGPDFDocument(CGDataProvider(data: data as CFData)!)!.page(at: 1)!
    }()
}

/// A flipped container so a block's content hangs from its top edge as its height is settled.
/// What File > Save Report… includes, chosen in the save panel's accessory view and remembered
/// between exports.
struct ReportOptions {
    var includeTestResults = true
    var categories = Set(ResultsCategory.allCases)

    private static let testResultsKey = "ReportIncludeTestResults"
    private static func key(for category: ResultsCategory) -> String {
        "ReportInclude.\(category)"
    }

    static var saved: ReportOptions {
        get {
            let defaults = UserDefaults.standard
            var options = ReportOptions()
            options.includeTestResults = defaults.object(forKey: testResultsKey) as? Bool ?? true
            options.categories = Set(ResultsCategory.allCases.filter {
                defaults.object(forKey: key(for: $0)) as? Bool ?? true
            })
            return options
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.includeTestResults, forKey: testResultsKey)
            for category in ResultsCategory.allCases {
                defaults.set(newValue.categories.contains(category), forKey: key(for: category))
            }
        }
    }
}

/// The save panel's "Include" checkboxes: Test Results, then one per chart category.
final class ReportOptionsAccessoryView: NSView {
    private let testResultsBox: NSButton
    private let categoryBoxes: [(category: ResultsCategory, box: NSButton)]

    init(options: ReportOptions) {
        testResultsBox = NSButton(checkboxWithTitle: "Test Results", target: nil, action: nil)
        testResultsBox.state = options.includeTestResults ? .on : .off
        categoryBoxes = ResultsCategory.allCases.map { category in
            let title = category == .smith ? "Smith Charts" : category.title.capitalized
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = options.categories.contains(category) ? .on : .off
            return (category, box)
        }
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "Include:")
        let boxes = [testResultsBox] + categoryBoxes.map(\.box)
        let columns = 2
        let rows = stride(from: 0, to: boxes.count, by: columns).map { start -> [NSView] in
            (start..<start + columns).map { $0 < boxes.count ? boxes[$0] : NSGridCell.emptyContentView }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 24
        let stack = NSStackView(views: [title, grid])
        stack.alignment = .top
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        frame.size = fittingSize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var options: ReportOptions {
        var options = ReportOptions()
        options.includeTestResults = testResultsBox.state == .on
        options.categories = Set(categoryBoxes.filter { $0.box.state == .on }.map(\.category))
        return options
    }
}

private final class ReportBlockView: NSView {
    override var isFlipped: Bool { true }
}

/// A heading waiting to be attached to the next chart rendered after it.
private struct PendingView {
    var view: NSView?
    mutating func take() -> NSView? {
        defer { view = nil }
        return view
    }
}
