import Cocoa
import MetalKit

/// Renders an EMSGeometryPreview -- the sliced board geometry the geometry pipeline step just
/// built for one simulation -- as a flattened top-down view: each copper layer filled in its own
/// (fully opaque) color, drawn back-to-front (bottom copper first, top copper last, so it reads
/// the way a real board does from above); vias (both real board ones and board-slicing's own
/// synthetic stitching vias) as an annular ring in the top layer's color, a gold stroke, and a
/// black hole -- matching how KiCad's own PCB editor renders a drilled hole as genuinely empty,
/// not another highlighted color; resolved ports as blue dots; the simulation's own cutout outline
/// stroked on top of everything. Metal-backed (not Core Graphics)
/// specifically so panning/zooming a real board's few hundred thousand via/copper vertices stays
/// smooth -- see scrollWheel(with:)/magnify(with:) for the interaction itself. Purely a passive
/// renderer otherwise -- GeometryViewController owns running the pipeline step and just assigns
/// the result to `preview`.
final class GeometryView: MTKView, MTKViewDelegate {
    var preview: EMSGeometryPreview? {
        didSet {
            rebuildBuffers()
            hasFitToView = false
            rebuildLegend()
            needsDisplay = true
        }
    }

    // Top-left origin, Y increasing downward -- purely an internal bookkeeping choice for this
    // view's own pixel space (matching mouse/scroll event coordinates), independent of the board
    // data's own orientation. See currentUniforms()'s doc comment for that part: board-space Y
    // increases *upward* (libkicad's own native frame, built from Gerber/pos.csv exports -- see
    // resolvePinRaw's doc comment in libkicad.cpp), the opposite of this view's pixel space, so the
    // board->pixel mapping below has an explicit extra negation to compensate.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!

    private var fillPositionBuffer: MTLBuffer?
    private var fillColorBuffer: MTLBuffer?
    private var fillVertexCount = 0
    private var outlinePositionBuffer: MTLBuffer?
    private var outlineColorBuffer: MTLBuffer?
    private var outlineVertexCount = 0

    // Board-space (simulation units, Y increasing upward) -> view-pixel-space (Y increasing
    // downward, matching isFlipped) affine transform: pixel = (board.x, -board.y) * viewScale +
    // (viewOffsetX, viewOffsetY) -- see resetViewIfNeeded()/currentUniforms() for where the Y
    // negation is actually applied. Reset to fit the whole board on screen whenever a new preview
    // arrives (see resetViewIfNeeded()); mutated in place by panning/zooming afterward so
    // interaction persists across redraws until the next preview.
    private var viewScale: CGFloat = 1
    private var viewOffsetX: CGFloat = 0
    private var viewOffsetY: CGFloat = 0
    private var hasFitToView = false
    private static let fitMargin: CGFloat = 24

    private let legendStack = NSStackView()
    private var lastPanPoint: CGPoint?

    convenience init() {
        self.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
    }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commonInit()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 4x MSAA -- copper polygon edges and via/port circle tessellation are otherwise visibly
    /// faceted, especially once zoomed in. MTKView handles the multisample texture and its resolve
    /// to the drawable on its own once `sampleCount` is set; the render pipeline just has to agree
    /// on the same sample count (see makePipelineState) or Metal rejects the pipeline at draw time.
    private static let sampleCount = 4

    private func commonInit() {
        delegate = self
        // On-demand rendering, not a continuous 60fps loop -- this view's content only ever
        // changes in response to a new preview or a pan/zoom gesture, both of which call
        // needsDisplay = true themselves.
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        sampleCount = Self.sampleCount

        if let device {
            commandQueue = device.makeCommandQueue()
            pipelineState = Self.makePipelineState(device: device, pixelFormat: colorPixelFormat)
        }

        setupLegend()
    }

    private static func makePipelineState(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "geometry_vertex"),
              let fragmentFunction = library.makeFunction(name: "geometry_fragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.rasterSampleCount = sampleCount
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipelineState, let commandQueue,
              let drawable = currentDrawable, let descriptor = currentRenderPassDescriptor else { return }

        resetViewIfNeeded()

        descriptor.colorAttachments[0].clearColor = Self.backgroundColor

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipelineState)

        var uniforms = currentUniforms()
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

        if fillVertexCount > 0, let positions = fillPositionBuffer, let colors = fillColorBuffer {
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fillVertexCount)
        }
        // Drawn after the fills, not before -- with fully opaque copper (see rebuildBuffers()),
        // an outline drawn first would just be painted over wherever copper covers it.
        if outlineVertexCount > 1, let positions = outlinePositionBuffer, let colors = outlineColorBuffer {
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: outlineVertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private struct Uniforms {
        var scale: SIMD2<Float>
        var offset: SIMD2<Float>
    }

    private func currentUniforms() -> Uniforms {
        let width = max(Float(bounds.width), 1)
        let height = max(Float(bounds.height), 1)
        // Board -> pixel (viewScale/viewOffset, with an extra Y negation -- board-space Y increases
        // upward, this view's own pixel space increases downward, see isFlipped's doc comment)
        // composed with pixel -> NDC (Metal clip space is Y-up, our pixel space is Y-down). The two
        // Y negations (board->pixel, pixel->NDC) cancel out, leaving a positive Y scale here --
        // that's not a mistake, it's board-Y-up composed with pixel-Y-down composed with
        // NDC-Y-up landing back on a positive coefficient.
        let scale = SIMD2<Float>(Float(2 * viewScale) / width, Float(2 * viewScale) / height)
        let offset = SIMD2<Float>(Float(2 * viewOffsetX) / width - 1, 1 - Float(2 * viewOffsetY) / height)
        return Uniforms(scale: scale, offset: offset)
    }

    // MARK: - Fit-to-view / pan / zoom

    private func resetViewIfNeeded() {
        guard !hasFitToView, let preview, preview.width > 0, preview.height > 0, bounds.width > 0, bounds.height > 0
        else { return }
        let availableWidth = max(bounds.width - Self.fitMargin * 2, 1)
        let availableHeight = max(bounds.height - Self.fitMargin * 2, 1)
        let scale = min(availableWidth / CGFloat(preview.width), availableHeight / CGFloat(preview.height))
        let renderedWidth = CGFloat(preview.width) * scale
        let renderedHeight = CGFloat(preview.height) * scale
        viewScale = scale
        viewOffsetX = (bounds.width - renderedWidth) / 2 - CGFloat(preview.xMin) * scale
        // + (yMin + height), not - yMin, to account for the board->pixel Y negation (see
        // currentUniforms()'s doc comment) -- the board's *maximum* Y (its northernmost point) is
        // what ends up at the smallest pixel Y (the top of the view), not its minimum.
        viewOffsetY = (bounds.height - renderedHeight) / 2 + CGFloat(preview.yMin + preview.height) * scale
        hasFitToView = true
    }

    /// Trackpad two-finger scroll (and a plain scroll wheel) pans the board around.
    override func scrollWheel(with event: NSEvent) {
        guard preview != nil else { return }
        viewOffsetX += event.scrollingDeltaX
        viewOffsetY += event.scrollingDeltaY
        needsDisplay = true
    }

    /// Pinch-to-zoom, anchored at the gesture's location so the board point under the cursor
    /// stays fixed on screen rather than the view re-centering around its own origin.
    override func magnify(with event: NSEvent) {
        guard preview != nil else { return }
        let anchor = convert(event.locationInWindow, from: nil)
        let factor = 1 + event.magnification
        zoom(by: factor, anchor: anchor)
    }

    private func zoom(by factor: CGFloat, anchor: CGPoint) {
        guard factor > 0 else { return }
        viewOffsetX = anchor.x - (anchor.x - viewOffsetX) * factor
        viewOffsetY = anchor.y - (anchor.y - viewOffsetY) * factor
        viewScale *= factor
        needsDisplay = true
    }

    /// Click-and-drag panning, for mice without a trackpad's two-finger scroll.
    override func mouseDown(with event: NSEvent) {
        lastPanPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard preview != nil, let lastPanPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        viewOffsetX += point.x - lastPanPoint.x
        viewOffsetY += point.y - lastPanPoint.y
        self.lastPanPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        lastPanPoint = nil
    }

    // MARK: - Scene construction

    private static let circleSegments = 20
    // Solid black, not a bright accent color -- a drilled hole is genuinely empty (no copper, no
    // substrate, just a void through the board), and KiCad's own PCB editor renders it that way
    // too. A bright color there reads as "more copper highlighted," not "a hole" -- especially
    // once the ring/stroke/hole margins are tight, where the whole via just looked like one solid
    // colored blob with no visible hole at all.
    private static let viaHoleColor = SIMD4<Float>(0, 0, 0, 1)
    // Gold, not white -- reads as a plated barrel wall (the stroke's real physical meaning) rather
    // than a plain highlight outline.
    private static let viaStrokeColor = SIMD4<Float>(0xEB / 255, 0xB5 / 255, 0x00 / 255, 1)
    private static let portColor = SIMD4<Float>(Float(NSColor.systemBlue.usingColorSpace(.deviceRGB)?.redComponent ?? 0.2),
                                                  Float(NSColor.systemBlue.usingColorSpace(.deviceRGB)?.greenComponent ?? 0.48),
                                                  Float(NSColor.systemBlue.usingColorSpace(.deviceRGB)?.blueComponent ?? 0.98),
                                                  1)
    // A fixed light grey, not the adaptive tertiaryLabelColor the outline used to use -- that
    // reads as near-invisible against the fixed dark canvas below in light-appearance mode.
    private static let outlineColor = SIMD4<Float>(0.7, 0.7, 0.7, 1)
    // 80% dark grey -- fixed regardless of light/dark appearance, matching the common EDA-tool
    // convention of a dark canvas independent of the rest of the app's own theme.
    private static let backgroundColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)

    private func rebuildBuffers() {
        guard let device, let preview else {
            fillVertexCount = 0
            outlineVertexCount = 0
            return
        }

        var fillPositions: [SIMD2<Float>] = []
        var fillColors: [SIMD4<Float>] = []

        // Back to front: bottom copper (last in `layers`) first, top copper (`layers[0]`, F.Cu)
        // last, so the topmost layer -- the one actually visible looking down at the board --
        // paints over everything beneath it, the way a real board looks from above.
        for index in preview.layers.indices.reversed() {
            let layer = preview.layers[index]
            let color = Self.simdColor(for: layer, index: index, total: preview.layers.count)
            for triangle in layer.triangles {
                fillPositions.append(SIMD2(Float(triangle.a.x), Float(triangle.a.y)))
                fillPositions.append(SIMD2(Float(triangle.b.x), Float(triangle.b.y)))
                fillPositions.append(SIMD2(Float(triangle.c.x), Float(triangle.c.y)))
                fillColors.append(contentsOf: [color, color, color])
            }
        }

        // Vias (both real board vias and board-slicing's own synthetic stitching vias -- see
        // EMSGeometryVia's doc comment, they render identically): three concentric opaque
        // capsule/stadium shapes, largest to smallest -- an annular ring in the top layer's color, a
        // gold stroke, then the black hole -- so painter's algorithm alone produces the ring/stroke/
        // hole look with no real stroke rendering needed. The ring and stroke are drawn on the via's
        // own *ring* centerline (ringPosition/ringPosition2 -- the real copper pad/ring's own shape,
        // independently sized from the hole's), the hole on its *own* (position/position2 -- the
        // real drilled hole's shape) -- the two only coincide exactly for a plain round via (every
        // stitching via, and most real ones); for an elongated one (e.g. a connector's oblong SHIELD
        // pad) they're genuinely different capsules, not just different radii on a shared one (see
        // GeometryPreviewBridge.mm's ringCapsuleForRealPad() for why that distinction matters -- an
        // earlier version here reused the hole's own centerline for the ring too, which rendered a
        // real board's oblong pads roughly 1.5x too big on both axes).
        if let topLayer = preview.layers.first {
            let ringColor = Self.simdColor(for: topLayer, index: 0, total: preview.layers.count)
            for via in preview.vias {
                let outerRadius = CGFloat(via.annularRingDiameter) / 2
                guard outerRadius > 0 else { continue }
                let holeRadius = min(CGFloat(via.diameter) / 2, outerRadius)
                // A fixed 1.35x multiplier on the hole radius (the old formula) leaves no room for
                // the colored ring at all on a real via, whose annular ring is usually only a small
                // margin wider than its hole (e.g. a 0.3mm hole in a 0.4mm pad) -- 1.35x the hole
                // radius met-or-exceeded the outer radius, so the stroke disc completely
                // covered the ring disc beneath it. Splitting the actual hole-to-outer-edge margin
                // instead always leaves both a visible stroke sliver and a visible ring, however
                // tight that margin is. Drawn on the ring's own centerline (not interpolated toward
                // the hole's, which can be a genuinely different shape/length) -- still reads as a
                // highlighted edge peeking out from under the ring, just always within the ring's
                // own real extent.
                let strokeRadius = holeRadius + (outerRadius - holeRadius) * 0.4
                Self.appendCapsule(from: via.ringPosition, to: via.ringPosition2, radius: outerRadius,
                                     color: ringColor, positions: &fillPositions, colors: &fillColors)
                Self.appendCapsule(from: via.ringPosition, to: via.ringPosition2, radius: strokeRadius,
                                     color: Self.viaStrokeColor, positions: &fillPositions, colors: &fillColors)
                Self.appendCapsule(from: via.position, to: via.position2, radius: holeRadius,
                                     color: Self.viaHoleColor, positions: &fillPositions, colors: &fillColors)
            }
        }

        // Ports, on top of everything else -- sized off the port's own trace width, the one real
        // physical dimension available for it, rather than an arbitrary constant.
        for port in preview.ports {
            let radius = max(CGFloat(port.width) / 2, 1)
            Self.appendDisc(center: port.position, radius: radius, color: Self.portColor,
                             positions: &fillPositions, colors: &fillColors)
        }

        fillVertexCount = fillPositions.count
        fillPositionBuffer = fillPositions.isEmpty ? nil : device.makeBuffer(
            bytes: fillPositions, length: MemoryLayout<SIMD2<Float>>.stride * fillPositions.count)
        fillColorBuffer = fillColors.isEmpty ? nil : device.makeBuffer(
            bytes: fillColors, length: MemoryLayout<SIMD4<Float>>.stride * fillColors.count)

        var outlinePositions = preview.outline.map { value -> SIMD2<Float> in
            let point = value.pointValue
            return SIMD2(Float(point.x), Float(point.y))
        }
        if let first = outlinePositions.first {
            outlinePositions.append(first) // Close the loop.
        }
        let outlineColors = Array(repeating: Self.outlineColor, count: outlinePositions.count)

        outlineVertexCount = outlinePositions.count
        outlinePositionBuffer = outlinePositions.isEmpty ? nil : device.makeBuffer(
            bytes: outlinePositions, length: MemoryLayout<SIMD2<Float>>.stride * outlinePositions.count)
        outlineColorBuffer = outlineColors.isEmpty ? nil : device.makeBuffer(
            bytes: outlineColors, length: MemoryLayout<SIMD4<Float>>.stride * outlineColors.count)
    }

    private static func appendDisc(center: CGPoint, radius: CGFloat, color: SIMD4<Float>,
                                    positions: inout [SIMD2<Float>], colors: inout [SIMD4<Float>]) {
        guard radius > 0 else { return }
        let cx = Float(center.x)
        let cy = Float(center.y)
        let r = Float(radius)
        let centerVertex = SIMD2<Float>(cx, cy)
        var previous = SIMD2<Float>(cx + r, cy)
        for segment in 1...circleSegments {
            let angle = Float(segment) / Float(circleSegments) * 2 * Float.pi
            let current = SIMD2<Float>(cx + r * cos(angle), cy + r * sin(angle))
            positions.append(contentsOf: [centerVertex, previous, current])
            colors.append(contentsOf: [color, color, color])
            previous = current
        }
    }

    /// A via's cross-section boundary, between capsule/stadium centerline endpoints `a`/`b` -- a
    /// plain circle around `a` when the two coincide (the ordinary round-via case, identical to
    /// appendDisc's own tessellation), or a stadium shape otherwise (an elongated via). Mirrors
    /// libgerber2ems's own `_viaPolygon` (simulation.cpp) point-for-point, so this preview draws
    /// exactly the shape the FDTD geometry actually uses -- see that function's own comment for why
    /// the boundary is built as two open (non-duplicated-endpoint) semicircle sweeps.
    private static func capsuleBoundary(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> [CGPoint] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        guard dx != 0 || dy != 0 else {
            return (0..<circleSegments).map { i in
                let angle = CGFloat(i) / CGFloat(circleSegments) * 2 * .pi
                return CGPoint(x: a.x + radius * cos(angle), y: a.y + radius * sin(angle))
            }
        }
        let lineAngle = atan2(dy, dx)
        let halfSegments = max(1, circleSegments / 2)
        // halfSegments *points* spanning a pi-radian sweep means halfSegments-1 *steps* -- dividing
        // by halfSegments instead undershoots the far endpoint by one step's worth of angle, leaving
        // each semicircle looking like it doesn't quite reach 180 degrees.
        let angleDenominator = max(1, halfSegments - 1)
        var points: [CGPoint] = []
        points.reserveCapacity(halfSegments * 2)
        for i in 0..<halfSegments {
            let angle = lineAngle - .pi / 2 + .pi * CGFloat(i) / CGFloat(angleDenominator)
            points.append(CGPoint(x: b.x + radius * cos(angle), y: b.y + radius * sin(angle)))
        }
        for i in 0..<halfSegments {
            let angle = lineAngle + .pi / 2 + .pi * CGFloat(i) / CGFloat(angleDenominator)
            points.append(CGPoint(x: a.x + radius * cos(angle), y: a.y + radius * sin(angle)))
        }
        return points
    }

    /// Fan-triangulated from the centerline's own midpoint -- valid for any interior point since a
    /// capsule (like a circle) is convex, exactly the same reasoning appendDisc's fan from its
    /// center relies on.
    private static func appendCapsule(from a: CGPoint, to b: CGPoint, radius: CGFloat, color: SIMD4<Float>,
                                        positions: inout [SIMD2<Float>], colors: inout [SIMD4<Float>]) {
        guard radius > 0 else { return }
        let boundary = capsuleBoundary(from: a, to: b, radius: radius)
        guard boundary.count >= 3 else { return }
        let centerVertex = SIMD2<Float>(Float((a.x + b.x) / 2), Float((a.y + b.y) / 2))
        for i in 0..<boundary.count {
            let current = SIMD2<Float>(Float(boundary[i].x), Float(boundary[i].y))
            let next = boundary[(i + 1) % boundary.count]
            let nextVertex = SIMD2<Float>(Float(next.x), Float(next.y))
            positions.append(contentsOf: [centerVertex, current, nextVertex])
            colors.append(contentsOf: [color, color, color])
        }
    }

    // MARK: - Legend overlay (plain AppKit, composited over the Metal layer)

    private func setupLegend() {
        legendStack.orientation = .vertical
        legendStack.alignment = .leading
        legendStack.spacing = 4
        legendStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(legendStack)
        NSLayoutConstraint.activate([
            legendStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            legendStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
        ])
    }

    private func rebuildLegend() {
        legendStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let layers = preview?.layers, !layers.isEmpty else { return }
        for (index, layer) in layers.enumerated() {
            let swatch = NSBox()
            swatch.boxType = .custom // No border by default for .custom (unlike the legacy box types borderType controls).
            swatch.fillColor = Self.color(for: layer, index: index, total: layers.count)
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let label = NSTextField(labelWithString: layer.name)
            label.font = .systemFont(ofSize: 11)
            // Fixed white, not the adaptive .labelColor -- see backgroundColor's own doc comment;
            // .labelColor would read as near-black-on-black in light appearance mode.
            label.textColor = .white

            let row = NSStackView(views: [swatch, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            legendStack.addArrangedSubview(row)
        }
    }

    // MARK: - Layer color resolution

    /// KiCad's own built-in default color theme, for boards whose active color theme couldn't be
    /// read at all (see EMSGeometryLayer.hexColor's doc comment) -- the same fallback
    /// EMSGeometryStepBridge's own libkicad_query::layerColors() call resolves to when nothing
    /// project-specific is configured, kept here too since that call can fail outright (no
    /// wx-headless color settings available at all) rather than just come back empty.
    private static let kicadDefaultLayerColors: [String: NSColor] = [
        "F.Cu": color(fromHex: "#C83434")!,
        "In1.Cu": color(fromHex: "#7FC87F")!,
        "In2.Cu": color(fromHex: "#CE7D2C")!,
        "In3.Cu": color(fromHex: "#4FCBCB")!,
        "In4.Cu": color(fromHex: "#DB628B")!,
        "B.Cu": color(fromHex: "#4D7FC4")!,
    ]

    /// Prefers the board's own configured color (read via libkicad -- see hexColor's doc comment),
    /// then KiCad's hardcoded default theme for a recognized layer name, then an evenly-spaced hue
    /// so even a board with more inner layers than the default table covers still gets a distinct
    /// color per layer.
    private static func color(for layer: EMSGeometryLayer, index: Int, total: Int) -> NSColor {
        if let hexColor = layer.hexColor, let parsed = color(fromHex: hexColor) {
            return parsed
        }
        if let defaultColor = kicadDefaultLayerColors[layer.name] {
            return defaultColor
        }
        guard total > 1 else { return .systemOrange }
        let hue = CGFloat(index) / CGFloat(total)
        return NSColor(calibratedHue: hue, saturation: 0.65, brightness: 0.85, alpha: 1)
    }

    /// Parses "#RRGGBB" or "#RRGGBBAA" (COLOR4D::ToHexString()'s own format on the C++ side).
    private static func color(fromHex hex: String) -> NSColor? {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else {
            return nil
        }
        let hasAlpha = digits.count == 8
        let shift = hasAlpha ? 24 : 16
        let red = CGFloat((value >> shift) & 0xFF) / 255
        let green = CGFloat((value >> (shift - 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (shift - 16)) & 0xFF) / 255
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1) // Always opaque.
    }

    /// Same resolution as color(for:index:total:), as the SIMD4<Float> RGBA Metal wants -- alpha
    /// forced to 1 (see color(fromHex:)'s own note), converting through deviceRGB since the parsed
    /// colors above are calibratedRGB, not necessarily directly component-readable otherwise.
    private static func simdColor(for layer: EMSGeometryLayer, index: Int, total: Int) -> SIMD4<Float> {
        let resolved = color(for: layer, index: index, total: total).usingColorSpace(.deviceRGB)
        return SIMD4<Float>(Float(resolved?.redComponent ?? 0.5), Float(resolved?.greenComponent ?? 0.5),
                             Float(resolved?.blueComponent ?? 0.5), 1)
    }
}
