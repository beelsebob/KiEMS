import Cocoa

/// KiCad net names can carry markup for parts that should render specially: `_{...}` / `^{...}` for
/// sub/superscript (e.g. "GND_{1}" or "V^{DD}"), `~{...}` for a negated/active-low signal (drawn with
/// an overline, e.g. "~{RESET}"), and a literal `{slash}` token standing in for a `/` character
/// (KiCad reserves a bare `/` as its hierarchical-sheet path separator within net names, so a net
/// actually named with a slash in it gets this escaped instead). Sections can nest (e.g. "~{A_{B}}",
/// a negated signal with a subscripted part) -- this turns that markup into a sequence of plain-text
/// segments for display, each carrying the cumulative effect of every level it's nested inside, and
/// the underlying net name string itself (as used for matching/storage everywhere else, e.g.
/// GroundNetHeuristic) is untouched.
enum NetNameFormatting {
    /// One lexical chunk of a formatted net name. `isOverlined` segments need a manually-drawn
    /// overline (see NetNameCellView) -- unlike sub/superscript, which NSAttributedString can render
    /// on its own via `.baselineOffset`, there's no built-in "overline" text attribute to lean on.
    struct Segment {
        let text: String
        let font: NSFont
        let baselineOffset: CGFloat
        let isOverlined: Bool
    }

    static func segments(for name: String, font: NSFont) -> [Segment] {
        segments(for: Substring(name), font: font, baselineOffset: 0, isOverlined: false)
    }

    /// A plain NSAttributedString built from `segments(for:font:)` -- sub/superscript renders
    /// correctly wherever this is used (it's a real NSAttributedString attribute), but `isOverlined`
    /// segments just render as plain text: nothing else here knows how to draw an overline. Only
    /// NetNameCellView, which draws segments itself, actually renders the overline.
    static func attributedString(for name: String, font: NSFont) -> NSAttributedString {
        attributedString(from: segments(for: name, font: font))
    }

    /// Shared by attributedString(for:font:) and the width measurement in size(for:) -- `color`
    /// omitted means "whatever the view drawing this will layer on separately" (attributedString(
    /// for:font:)'s callers all set their own color via other means; the drawing/measuring paths
    /// below always pass one explicitly since NSAttributedString has no notion of "unset color").
    private static func attributedString(from segments: [Segment], color: NSColor? = nil) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: segment.font,
                .baselineOffset: segment.baselineOffset,
            ]
            if let color {
                attributes[.foregroundColor] = color
            }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }

    /// The on-screen box draw(_:in:color:) needs to fit `segments` -- width is the full run's
    /// attributed-string width (built the same way draw(_:in:color:) builds it to actually render),
    /// height is whichever segment's font is tallest (see draw(_:in:color:)'s own comment on why
    /// that's the right measure to vertically center a mixed-font run against). Callers doing Auto
    /// Layout (see NetNameView) use this as their intrinsicContentSize.
    static func size(for segments: [Segment]) -> CGSize {
        guard !segments.isEmpty else { return .zero }
        let lineHeight = segments.map { $0.font.ascender - $0.font.descender }.max() ?? 0
        return CGSize(width: attributedString(from: segments).size().width, height: lineHeight)
    }

    /// Draws `segments` into `bounds` of a flipped view, vertically centered, including the
    /// manually-drawn overline bars `isOverlined` segments need (see NetNameCellView's own doc
    /// comment on why: sub/superscript is a real NSAttributedString attribute, but there's no
    /// built-in "overline" one to lean on). Shared by every view that renders a formatted net name
    /// -- NetNameCellView (table cells) and NetNameView (plain labels) -- so this one piece of
    /// AppKit-doesn't-have-overline drawing logic lives in exactly one place.
    static func draw(_ segments: [Segment], in bounds: CGRect, color: NSColor) {
        guard !segments.isEmpty else { return }
        let fullString = attributedString(from: segments, color: color)

        // draw(at:) positions the WHOLE string's bounding box at the given point -- that box's height
        // is set by whichever segment's font is tallest (almost always the base, non-sub/superscript
        // one), so vertical centering has to be measured against that, not any single segment.
        let lineHeight = segments.map { $0.font.ascender - $0.font.descender }.max() ?? 0
        let originY = (bounds.height - lineHeight) / 2
        fullString.draw(at: NSPoint(x: bounds.minX, y: originY))

        // Where the baseline actually sits: the tallest font's ascender below the box's top edge.
        let tallestFont = segments.max {
            ($0.font.ascender - $0.font.descender) < ($1.font.ascender - $1.font.descender)
        }?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let baselineY = originY + tallestFont.ascender

        // NSAttributedString has no API to ask "where did this substring land when drawn as part of
        // the larger string" -- measuring the width of each successive prefix gives the same answer
        // here, since each segment already carries its own font/attributes (a hard font-change
        // boundary, so there's no cross-segment kerning to throw the measurement off).
        //
        // A run of consecutive overlined segments (e.g. a negated section with a subscript in it,
        // "~{A_{B}}") gets ONE bar spanning the whole run, not one per segment -- otherwise a
        // subscript/superscript inside a negated section would get its own bar at a different height,
        // reading as a break in the line instead of one continuous overline. That bar sits at
        // whichever segment in the run needs the most clearance (the smallest -- i.e. topmost, since
        // this view is flipped -- glyphTopY among them), so it clears every segment's glyphs, sub or
        // super included.
        color.setStroke()
        var prefixLength = 0
        var startX: CGFloat = bounds.minX
        var runStartX: CGFloat?
        var runTopY: CGFloat = 0

        func flushRun(endingAt endX: CGFloat) {
            guard let runStartX else { return }
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: runStartX, y: runTopY))
            path.line(to: NSPoint(x: endX, y: runTopY))
            path.stroke()
        }

        for segment in segments {
            prefixLength += (segment.text as NSString).length
            let endX = bounds.minX + fullString.attributedSubstring(
                from: NSRange(location: 0, length: prefixLength)).size().width
            if segment.isOverlined {
                // baselineOffset raises glyphs on screen for positive values, in both flipped and
                // non-flipped views -- in this flipped view (y grows downward), that's `-offset`.
                let glyphTopY = baselineY - segment.baselineOffset - segment.font.ascender
                if let existingRunStartX = runStartX {
                    runStartX = existingRunStartX
                    runTopY = min(runTopY, glyphTopY)
                } else {
                    runStartX = startX
                    runTopY = glyphTopY
                }
            } else {
                flushRun(endingAt: startX)
                runStartX = nil
            }
            startX = endX
        }
        flushRun(endingAt: startX)
    }

    /// Renders `message` (a full English sentence libgerber2ems built, e.g. a pipeline error) mostly
    /// as plain text, except substrings the message itself double-quotes -- every C++ site that
    /// interpolates a net name, footprint reference, or layer name into a message wraps it in literal
    /// `"..."` this way, consistently, so quote-splitting is a reliable way to find embedded
    /// identifiers in an otherwise-opaque prose string without libgerber2ems having to mark them up
    /// any more explicitly than it already does. Each quoted substring is run through
    /// segments(for:font:), so a net name's own sub/superscript/negation markup (e.g. "GND_{1}" or
    /// "~{RESET}") renders correctly wherever it happens to appear inside a full message, not just in
    /// the source list. Harmless when a quoted substring isn't actually a net name (a footprint
    /// reference or layer name, say): segments(for:font:) only treats `_{...}`/`^{...}`/`~{...}`/
    /// `{slash}` specially, none of which are otherwise meaningful there, so plain quoted text just
    /// passes through unchanged. An odd number of quote characters (a malformed message) degrades to
    /// treating everything after the last one as quoted -- never worse than showing it as plain text.
    ///
    /// `maxPlainTextLength` caps how many characters of *plain* (unquoted) prose this will show in
    /// total before cutting the rest with a plain "…" -- deliberately not a cap on the message as a
    /// whole: AppKit's own line-break/truncation modes operate on a whole line with no concept of a
    /// protected range, so the only way to guarantee a quoted identifier is never the part an
    /// ellipsis lands inside of is to do the fitting ourselves, here, before AppKit ever sees the
    /// final string -- every quoted segment is always included in full, whatever its own length,
    /// with only the surrounding prose ever counted against the budget. If a message is still too
    /// long after that (a pathologically long net name, say), that's the caller's own layout to
    /// handle -- this only ever protects *which part* gets shortened, not a hard total-size promise.
    static func attributedString(embeddingNetNamesIn message: String, font: NSFont,
                                  maxPlainTextLength: Int = 220) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let quoteAttributes: [NSAttributedString.Key: Any] = [.font: font]
        var isInsideQuotes = false
        var plainTextBudgetRemaining = maxPlainTextLength
        for component in message.split(separator: "\"", omittingEmptySubsequences: false) {
            defer { isInsideQuotes.toggle() }
            if isInsideQuotes {
                // Never counted against the budget, and never itself truncated -- see this method's
                // own doc comment on why a quoted identifier is always shown whole or not at all.
                result.append(NSAttributedString(string: "\"", attributes: quoteAttributes))
                result.append(attributedString(for: String(component), font: font))
                result.append(NSAttributedString(string: "\"", attributes: quoteAttributes))
                continue
            }
            guard plainTextBudgetRemaining > 0 else { continue }
            if component.count <= plainTextBudgetRemaining {
                result.append(NSAttributedString(string: String(component), attributes: quoteAttributes))
                plainTextBudgetRemaining -= component.count
            } else {
                let cutoff = component.index(component.startIndex, offsetBy: plainTextBudgetRemaining)
                result.append(NSAttributedString(string: component[..<cutoff] + "…", attributes: quoteAttributes))
                plainTextBudgetRemaining = 0
            }
        }
        return result
    }

    /// `baselineOffset`/`isOverlined` are whatever every enclosing `_{}`/`^{}`/`~{}` section (if any)
    /// already contributed -- a section nested inside another compounds on top of it (e.g. a
    /// subscript nested inside a negated section is both smaller/lowered *and* overlined), rather
    /// than each level starting fresh.
    private static func segments(for text: Substring, font: NSFont, baselineOffset: CGFloat,
                                  isOverlined: Bool) -> [Segment] {
        var result: [Segment] = []
        var remainder = text

        while let firstCharacter = remainder.first {
            if remainder.hasPrefix("{slash}") {
                result.append(Segment(text: "/", font: font, baselineOffset: baselineOffset, isOverlined: isOverlined))
                remainder = remainder.dropFirst("{slash}".count)
                continue
            }
            if firstCharacter == "_", let (body, rest) = matchedBody(after: remainder) {
                let scriptFont = NSFont.systemFont(ofSize: font.pointSize * 0.7)
                // Positive baselineOffset raises text (superscript); negative lowers it (subscript).
                let offset = baselineOffset + font.pointSize * -0.15
                result.append(contentsOf: segments(for: body, font: scriptFont, baselineOffset: offset,
                                                     isOverlined: isOverlined))
                remainder = rest
                continue
            }
            if firstCharacter == "^", let (body, rest) = matchedBody(after: remainder) {
                let scriptFont = NSFont.systemFont(ofSize: font.pointSize * 0.7)
                let offset = baselineOffset + font.pointSize * 0.35
                result.append(contentsOf: segments(for: body, font: scriptFont, baselineOffset: offset,
                                                     isOverlined: isOverlined))
                remainder = rest
                continue
            }
            if firstCharacter == "~", let (body, rest) = matchedBody(after: remainder) {
                result.append(contentsOf: segments(for: body, font: font, baselineOffset: baselineOffset,
                                                     isOverlined: true))
                remainder = rest
                continue
            }
            result.append(Segment(text: String(firstCharacter), font: font, baselineOffset: baselineOffset,
                                   isOverlined: isOverlined))
            remainder.removeFirst()
        }
        return result
    }

    /// `remainder` starts with the marker character itself (`_`, `^`, or `~`). Matches the `{...}`
    /// section right after it by counting brace depth -- rather than just jumping to the first `}`,
    /// which would truncate a body that itself contains a nested section (e.g. in "~{A_{B}}", the
    /// correct body is "A_{B}", not "A_{B", cut short at the inner `_{B}`'s own closing brace).
    /// Returns the section's contents plus whatever follows its closing brace -- or nil if the marker
    /// isn't actually followed by a well-formed, properly-closed `{...}` section, in which case the
    /// marker is just a literal character.
    private static func matchedBody(after remainder: Substring) -> (Substring, Substring)? {
        let afterMarker = remainder.dropFirst()
        guard afterMarker.first == "{" else { return nil }

        var depth = 0
        var index = afterMarker.startIndex
        while index < afterMarker.endIndex {
            switch afterMarker[index] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    let body = afterMarker[afterMarker.index(after: afterMarker.startIndex)..<index]
                    let rest = afterMarker[afterMarker.index(after: index)...]
                    return (body, rest)
                }
            default:
                break
            }
            index = afterMarker.index(after: index)
        }
        return nil // unterminated -- no matching close brace
    }
}
