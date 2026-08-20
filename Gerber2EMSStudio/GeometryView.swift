import Cocoa
import MetalKit
import simd

/// Renders an EMSGeometryPreview -- the sliced board geometry the geometry pipeline step just
/// built for one simulation -- as a real, opaque 3D board (copper layers spread across the board's
/// own real Z thickness, same approach as FieldView's own board-reference render -- see
/// rebuildBoardBuffers()'s own doc comment): each layer filled in its own fully opaque color; vias
/// (both real board ones and board-slicing's own synthetic stitching vias) as an annular ring in
/// the top layer's color, a gold stroke, and a black hole -- matching how KiCad's own PCB editor
/// renders a drilled hole as genuinely empty, not another highlighted color; resolved ports as blue
/// dots; rejected stitching-via candidate positions as black crosses (see
/// EMSGeometryPreview.failedViaAttempts); the simulation's own cutout outline stroked on top.
///
/// Camera: an orbit camera (mouse-drag rotate, scroll/magnify zoom -- same interaction as
/// FieldView, sharing its camera math via Board3DMath.swift) but *orthographic*, not perspective,
/// defaulting to a classic isometric angle -- an orthographic camera has no perspective
/// foreshortening, so rotating to look straight down any one axis renders exactly as flat/2D as
/// the old top-down-only view this replaces, while every other angle still reads as genuinely 3D.
///
/// Grid lines (preview.gridLinesX/Y/Z, see showGrid) are drawn for whichever *two* axes are least
/// aligned with the current camera direction -- e.g. looking straight down Z (the old view's only
/// angle) draws the X/Y crosshatch exactly as before; rotate to look down X instead and it switches
/// to a Y/Z crosshatch. Drawing all three axes' worth of lines at once, always, would turn a real
/// board's dense mesh into an unreadable 3D lattice; this keeps exactly one flat, readable grid on
/// screen at a time, on whichever plane is actually facing the camera. See rebuildGridBuffers()'s
/// own doc comment for how the three (one-per-excluded-axis) grid planes are built.
///
/// Metal-backed (not Core Graphics) specifically so panning/zooming/orbiting a real board's few
/// hundred thousand via/copper vertices stays smooth. Purely a passive renderer otherwise --
/// GeometryViewController owns running the pipeline step and just assigns the result to `preview`.
final class GeometryView: MTKView, MTKViewDelegate {
    var preview: EMSGeometryPreview? {
        didSet {
            rebuildBoardBuffers()
            rebuildGridBuffers()
            hasFitCamera = false
            rebuildLegend()
            needsDisplay = true
        }
    }

    /// Whether to draw the current-facing pair of grid lines (see this class's own top comment) --
    /// purely a display toggle, independent of whether grid data is actually available yet
    /// (GeometryViewController is responsible for not turning this on before the Grid pipeline
    /// stage has run; empty gridLinesX/Y/Z just draws nothing). Doesn't rebuild buffers on its own,
    /// since the grid buffers were already built from the same `preview` this toggles visibility
    /// for.
    var showGrid: Bool = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    private var commandQueue: MTLCommandQueue!
    private var opaquePipelineState: MTLRenderPipelineState!
    /// Real depth test *and* write -- unlike FieldView's own translucent overlay/voxel passes
    /// (which can't use a real depth test at all, see paintersDepthStencilState's own doc comment
    /// there), every draw in this view is fully opaque, so a standard depth-tested pipeline handles
    /// occlusion correctly regardless of submission order -- no per-frame back-to-front layer
    /// sorting needed here the way FieldView's own board-reference render still requires.
    private var depthStencilState: MTLDepthStencilState!

    // MARK: - Board geometry (layers + vias + ports, one combined opaque triangle buffer)

    private var boardPositionBuffer: MTLBuffer?
    private var boardColorBuffer: MTLBuffer?
    private var boardVertexCount = 0

    private var outlinePositionBuffer: MTLBuffer?
    private var outlineColorBuffer: MTLBuffer?
    private var outlineVertexCount = 0

    private var crossPositionBuffer: MTLBuffer?
    private var crossColorBuffer: MTLBuffer?
    private var crossVertexCount = 0

    // MARK: - Grid lines: one precomputed crosshatch plane per possible *excluded* axis (see
    // rebuildGridBuffers()'s own doc comment) -- draw(in:) picks exactly one to draw each frame,
    // based on the current camera direction, rather than rebuilding geometry every frame.

    private struct LineBuffer {
        var positionBuffer: MTLBuffer?
        var colorBuffer: MTLBuffer?
        var vertexCount = 0
    }
    private var gridPlaneExcludingX = LineBuffer() // Y/Z crosshatch -- drawn when X is most camera-aligned.
    private var gridPlaneExcludingY = LineBuffer() // X/Z crosshatch -- drawn when Y is most camera-aligned.
    private var gridPlaneExcludingZ = LineBuffer() // X/Y crosshatch -- drawn when Z is most camera-aligned (the old view's only case).

    // MARK: - Orbit camera (shares its math with FieldView -- see Board3DMath.swift)

    private static let isometricElevation: Float = atan(1 / Float(2).squareRoot())
    private var azimuth: Float = -.pi / 4
    private var elevation: Float = GeometryView.isometricElevation
    private var distance: Float = 1
    private var target = Position3(0, 0, 0)
    private var sceneRadius: Float = 1
    private var hasFitCamera = false
    private static let minElevation: Float = -.pi / 2 * 0.98
    private static let maxElevation: Float = .pi / 2 * 0.98
    private var lastDragPoint: CGPoint?

    private let legendStack = NSStackView()

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
    /// faceted, especially once zoomed in.
    private static let sampleCount = 4

    private func commonInit() {
        delegate = self
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = Self.sampleCount

        if let device {
            commandQueue = device.makeCommandQueue()
            opaquePipelineState = Self.makePipelineState(device: device, pixelFormat: colorPixelFormat)
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)
        }

        setupLegend()
    }

    /// Reuses FieldShaders.metal's own `field_overlay_vertex`/`field_overlay_fragment` -- the same
    /// "positions + colors + one view-projection uniform" shader pair FieldView's own board
    /// reference render uses (see this view's own top comment: requirement 1 is to reuse that same
    /// 3D board-drawing code, not reimplement it) -- just with blending off, since every draw here
    /// is opaque rather than FieldView's fixed-alpha translucent reference plane.
    private static func makePipelineState(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "field_overlay_vertex"),
              let fragmentFunction = library.makeFunction(name: "field_overlay_fragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = sampleCount
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue, let opaquePipelineState, let depthStencilState,
              let drawable = currentDrawable, let descriptor = currentRenderPassDescriptor else { return }
        resetCameraIfNeeded()

        descriptor.colorAttachments[0].clearColor = Self.backgroundColor
        descriptor.depthAttachment.clearDepth = 1.0

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var uniforms = FieldUniformsGPU(viewProjection: currentProjectionMatrix() * lookAt(
            eye: currentEyePosition(), center: SIMD3(target.x, target.y, target.z), up: SIMD3(0, 0, 1)))

        encoder.setRenderPipelineState(opaquePipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 2)

        // Real depth test/write throughout (see depthStencilState's own doc comment) -- draw order
        // below doesn't affect the final image's correctness, only which surfaces are even eligible
        // to occlude which others; board geometry is drawn first purely so it establishes the main
        // occlusion surface before the thinner reference elements.
        if boardVertexCount > 0, let positions = boardPositionBuffer, let colors = boardColorBuffer {
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: boardVertexCount)
        }
        if outlineVertexCount > 1, let positions = outlinePositionBuffer, let colors = outlineColorBuffer {
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: outlineVertexCount)
        }
        // Each cross is two independent 2-vertex segments (see appendCross()) -- .line, not
        // .lineStrip, draws vertex pairs (0,1), (2,3), ... as disconnected segments rather than
        // joining every cross into one continuous zigzag.
        if crossVertexCount > 1, let positions = crossPositionBuffer, let colors = crossColorBuffer {
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: crossVertexCount)
        }
        if showGrid {
            let activeGrid = gridPlane(excluding: mostAlignedAxis())
            if activeGrid.vertexCount > 1, let positions = activeGrid.positionBuffer, let colors = activeGrid.colorBuffer {
                encoder.setVertexBuffer(positions, offset: 0, index: 0)
                encoder.setVertexBuffer(colors, offset: 0, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: activeGrid.vertexCount)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Camera math

    private func currentEyePosition() -> SIMD3<Float> {
        SIMD3<Float>(target.x + distance * cos(elevation) * cos(azimuth),
                     target.y + distance * cos(elevation) * sin(azimuth),
                     target.z + distance * sin(elevation))
    }

    /// Unit vector from the camera toward `target` -- used only to decide which world axis is most
    /// aligned with the current view direction (see mostAlignedAxis()), so grid lines can be drawn
    /// for the other two (see this class's own top comment).
    private func forwardDirection() -> SIMD3<Float> {
        SIMD3<Float>(cos(elevation) * cos(azimuth), cos(elevation) * sin(azimuth), sin(elevation))
    }

    private enum Axis3 { case x, y, z }

    private func mostAlignedAxis() -> Axis3 {
        let f = forwardDirection()
        let ax = abs(f.x), ay = abs(f.y), az = abs(f.z)
        if ax >= ay, ax >= az { return .x }
        if ay >= az { return .y }
        return .z
    }

    private func gridPlane(excluding axis: Axis3) -> LineBuffer {
        switch axis {
        case .x: return gridPlaneExcludingX
        case .y: return gridPlaneExcludingY
        case .z: return gridPlaneExcludingZ
        }
    }

    private func currentProjectionMatrix() -> simd_float4x4 {
        let aspect = Float(max(drawableSize.width, 1) / max(drawableSize.height, 1))
        // Same near/far bracketing as FieldView's own currentProjectionMatrix() (see its own doc
        // comment for why a fixed distance-relative ratio caused severe z-fighting) -- unrelated to
        // this being orthographic rather than perspective, the depth-precision problem it solves is
        // identical either way.
        let effectiveRadius = min(sceneRadius, distance)
        let near = max(distance - effectiveRadius * 1.5, distance * 0.01, 0.001)
        let far = max(distance + effectiveRadius * 1.5, near + 0.001)
        // Isometric-style camera: orthographic, not perspective (see this view's own top comment)
        // -- `distance` still drives the ortho window's own size, rather than a separate zoom
        // variable, so the scroll/magnify handlers below (borrowed from FieldView) work unchanged;
        // 0.8 is a tuned constant giving a similar initial framing to FieldView's own perspective
        // FOV at the same `distance` -- there's no single "correct" value for an orthographic zoom.
        let height = distance * 0.8
        let width = height * aspect
        return orthographic(width: width, height: height, near: near, far: far)
    }

    // MARK: - Fit-to-view / orbit / zoom

    private func resetCameraIfNeeded() {
        guard !hasFitCamera else { return }
        guard let box = currentBoundingBox() else { return }
        target = Position3((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2, (box.minZ + box.maxZ) / 2)
        let diagonal = sqrt(pow(box.maxX - box.minX, 2) + pow(box.maxY - box.minY, 2) + pow(box.maxZ - box.minZ, 2))
        sceneRadius = max(diagonal / 2, 0.001)
        distance = max(diagonal, 1) * 1.4
        hasFitCamera = true
    }

    private func currentBoundingBox() -> (minX: Float, maxX: Float, minY: Float, maxY: Float, minZ: Float,
                                           maxZ: Float)? {
        guard let preview, preview.width > 0, preview.height > 0 else { return nil }
        let minX = Float(preview.xMin)
        let minY = Float(preview.yMin)
        // The board's own real layer Z extent (see EMSGeometryLayer.z's own doc comment), not
        // pmlInnerZMin/Max (now "board + real margin," ~2mm past the board on each side -- see that
        // property's own doc comment -- comfortably wider than the board itself) and not
        // gridLinesZ's own min/max (the *full* FDTD domain, PML band included, wider still).
        // Fitting the camera to either would leave the actual board a small sliver in the middle of
        // the view. Matches X/Y's own precedent just above (fit to preview.xMin/width, the board's
        // own box, not the grid's). All-zero (a flat board) if there are no layers yet.
        let zValues = preview.layers.map { Float($0.z) }
        let minZ = zValues.min() ?? 0
        let maxZ = zValues.max() ?? 0
        return (minX, minX + Float(preview.width), minY, minY + Float(preview.height), minZ, maxZ)
    }

    /// Orbit: drag left/right to rotate azimuth, up/down to tilt elevation (clamped shy of the
    /// poles to avoid a gimbal flip -- see minElevation/maxElevation). No panning -- the orbit
    /// target is always the board's own bounding-box center, matching FieldView's own interaction
    /// model exactly.
    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastDragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastDragPoint.x)
        let dy = Float(point.y - lastDragPoint.y)
        let sensitivity: Float = 0.01
        azimuth -= dx * sensitivity
        elevation = min(max(elevation + dy * sensitivity, Self.minElevation), Self.maxElevation)
        self.lastDragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard preview != nil else { return }
        let factor = Float(1 - event.scrollingDeltaY * 0.01)
        zoom(by: factor)
    }

    override func magnify(with event: NSEvent) {
        guard preview != nil else { return }
        zoom(by: Float(1 - event.magnification))
    }

    private func zoom(by factor: Float) {
        guard factor > 0 else { return }
        distance = min(max(distance * factor, 0.01), 1_000_000_000)
        needsDisplay = true
    }

    // MARK: - Board geometry construction

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
    // A muted cyan -- distinct from the plain grey outline/legend text and every copper color in
    // kicadDefaultLayerColors, so a mesh line stays identifiable crossing any layer's fill.
    private static let gridLineColor = SIMD4<Float>(0.3, 0.75, 0.8, 1)
    // A dim magenta -- distinct from the cyan core-mesh color above, marking a line that falls in
    // the PML band GridGenerator appends beyond the core mesh's own extent on any axis (outside
    // preview.pmlInnerXMin/XMax/YMin/YMax/ZMin/ZMax), so it's visually obvious which of a run's
    // grid lines are actual physical mesh vs. absorbing-boundary padding -- Z included: the board
    // needs a PML/absorbing region in Z too (openEMS's Set_BC_PML() is applied on all 6 domain
    // faces, not just the 4 X/Y ones), so its own graded margin cells beyond the substrate stack's
    // top/bottom get the same highlighting as X/Y's.
    private static let pmlLineColor = SIMD4<Float>(0.85, 0.25, 0.85, 1)
    // Solid black -- distinct from every other marker color here (copper fills, gold via stroke,
    // blue ports), reads unambiguously as "nothing was placed here" rather than another kind of
    // real geometry.
    private static let failedViaAttemptColor = SIMD4<Float>(0, 0, 0, 1)
    // Board-space (sim units) fallback half-length for a failed-via-attempt cross, used only when
    // this preview has no real/stitching via to size it off of (see rebuildBoardBuffers()) -- 0.15mm
    // at 10 sim units/micron (see SlicedBoard's own doc comment on the sim-unit convention).
    private static let failedViaAttemptFallbackHalfLength: CGFloat = 1500
    // 80% dark grey -- fixed regardless of light/dark appearance, matching the common EDA-tool
    // convention of a dark canvas independent of the rest of the app's own theme.
    private static let backgroundColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)

    /// Builds the one combined opaque triangle buffer for every copper layer, via, and port. Each
    /// copper layer is placed at its own real Z (layer.z -- the cumulative real substrate thickness
    /// above it, exactly matching where the actual FDTD simulation places it, not an even-spacing
    /// approximation across the board's own extent -- see EMSGeometryLayer.z's own doc comment).
    private func rebuildBoardBuffers() {
        guard let device, let preview else {
            boardVertexCount = 0
            outlineVertexCount = 0
            crossVertexCount = 0
            return
        }

        let layerZValues = preview.layers.map { Float($0.z) }
        let topZ = layerZValues.max() ?? 0
        let bottomZ = layerZValues.min() ?? 0
        // Vias/ports/outline sit visibly above every copper layer, not coincident with the topmost
        // one -- same z-fighting concern FieldView's own markerZ avoids, same fix (a small nudge,
        // 1% of board thickness, rather than reusing the topmost layer's own Z exactly).
        let markerZ = topZ + max(topZ - bottomZ, 1) * 0.01

        var positions: [Position3] = []
        var colors: [SIMD4<Float>] = []

        for (index, layer) in preview.layers.enumerated() {
            let color = Self.simdColor(for: layer, index: index, total: preview.layers.count)
            let z = Float(layer.z)
            for triangle in layer.triangles {
                positions.append(contentsOf: [Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                                               Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                                               Position3(Float(triangle.c.x), Float(triangle.c.y), z)])
                colors.append(contentsOf: [color, color, color])
            }
        }

        // Vias (both real board vias and board-slicing's own synthetic stitching vias -- see
        // EMSGeometryVia's doc comment, they render identically): three concentric opaque
        // capsule/stadium shapes, largest to smallest -- an annular ring in the top layer's color, a
        // gold stroke, then the black hole -- real depth test/write above resolves the stacking
        // order correctly regardless of draw order, unlike the old flat 2D view's painter's
        // algorithm, which relied on this exact largest-to-smallest submission order.
        if let topLayer = preview.layers.first {
            let ringColor = Self.simdColor(for: topLayer, index: 0, total: preview.layers.count)
            for via in preview.vias {
                let outerRadius = CGFloat(via.annularRingDiameter) / 2
                guard outerRadius > 0 else { continue }
                let holeRadius = min(CGFloat(via.diameter) / 2, outerRadius)
                let strokeRadius = holeRadius + (outerRadius - holeRadius) * 0.4
                Self.appendCapsule(from: via.ringPosition, to: via.ringPosition2, radius: outerRadius, z: markerZ,
                                     color: ringColor, positions: &positions, colors: &colors)
                Self.appendCapsule(from: via.ringPosition, to: via.ringPosition2, radius: strokeRadius, z: markerZ,
                                     color: Self.viaStrokeColor, positions: &positions, colors: &colors)
                Self.appendCapsule(from: via.position, to: via.position2, radius: holeRadius, z: markerZ,
                                     color: Self.viaHoleColor, positions: &positions, colors: &colors)
            }
        }

        for port in preview.ports {
            let radius = max(CGFloat(port.width) / 2, 1)
            Self.appendDisc(center: port.position, radius: radius, z: markerZ, color: Self.portColor,
                             positions: &positions, colors: &colors)
        }

        boardVertexCount = positions.count
        boardPositionBuffer = positions.isEmpty ? nil : device.makeBuffer(
            bytes: positions, length: MemoryLayout<Position3>.stride * positions.count)
        boardColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count)

        var outlinePositions: [Position3] = preview.outline.map { value in
            let point = value.pointValue
            return Position3(Float(point.x), Float(point.y), markerZ)
        }
        if let first = outlinePositions.first {
            outlinePositions.append(first) // Close the loop.
        }
        let outlineColors = Array(repeating: Self.outlineColor, count: outlinePositions.count)

        outlineVertexCount = outlinePositions.count
        outlinePositionBuffer = outlinePositions.isEmpty ? nil : device.makeBuffer(
            bytes: outlinePositions, length: MemoryLayout<Position3>.stride * outlinePositions.count)
        outlineColorBuffer = outlineColors.isEmpty ? nil : device.makeBuffer(
            bytes: outlineColors, length: MemoryLayout<SIMD4<Float>>.stride * outlineColors.count)

        // Sized off a real via's own hole diameter when this preview has one (either a placed
        // stitching via or a real board via -- both use the same EMSGeometryVia.diameter field), so
        // a cross reads as roughly "the via that didn't get placed here" rather than an arbitrary
        // mark; falls back to a fixed board-space size only for the degenerate case of a preview
        // with failed attempts but no successfully-placed via anywhere to size off of.
        let crossHalfLength = preview.vias.first.map { CGFloat($0.diameter) / 2 } ?? Self.failedViaAttemptFallbackHalfLength
        var crossPositions: [Position3] = []
        var crossColors: [SIMD4<Float>] = []
        for value in preview.failedViaAttempts {
            Self.appendCross(center: value.pointValue, halfLength: crossHalfLength, z: markerZ,
                              color: Self.failedViaAttemptColor, positions: &crossPositions, colors: &crossColors)
        }
        crossVertexCount = crossPositions.count
        crossPositionBuffer = crossPositions.isEmpty ? nil : device.makeBuffer(
            bytes: crossPositions, length: MemoryLayout<Position3>.stride * crossPositions.count)
        crossColorBuffer = crossColors.isEmpty ? nil : device.makeBuffer(
            bytes: crossColors, length: MemoryLayout<SIMD4<Float>>.stride * crossColors.count)
    }

    private static func appendCross(center: CGPoint, halfLength: CGFloat, z: Float, color: SIMD4<Float>,
                                     positions: inout [Position3], colors: inout [SIMD4<Float>]) {
        guard halfLength > 0 else { return }
        let cx = Float(center.x)
        let cy = Float(center.y)
        let h = Float(halfLength)
        positions.append(contentsOf: [
            Position3(cx - h, cy - h, z), Position3(cx + h, cy + h, z),
            Position3(cx - h, cy + h, z), Position3(cx + h, cy - h, z),
        ])
        colors.append(contentsOf: [color, color, color, color])
    }

    private static func appendDisc(center: CGPoint, radius: CGFloat, z: Float, color: SIMD4<Float>,
                                    positions: inout [Position3], colors: inout [SIMD4<Float>]) {
        guard radius > 0 else { return }
        let cx = Float(center.x)
        let cy = Float(center.y)
        let r = Float(radius)
        let centerVertex = Position3(cx, cy, z)
        var previous = Position3(cx + r, cy, z)
        for segment in 1...circleSegments {
            let angle = Float(segment) / Float(circleSegments) * 2 * Float.pi
            let current = Position3(cx + r * cos(angle), cy + r * sin(angle), z)
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
    private static func appendCapsule(from a: CGPoint, to b: CGPoint, radius: CGFloat, z: Float, color: SIMD4<Float>,
                                       positions: inout [Position3], colors: inout [SIMD4<Float>]) {
        guard radius > 0 else { return }
        let boundary = capsuleBoundary(from: a, to: b, radius: radius)
        guard boundary.count >= 3 else { return }
        let centerVertex = Position3(Float((a.x + b.x) / 2), Float((a.y + b.y) / 2), z)
        for i in 0..<boundary.count {
            let current = Position3(Float(boundary[i].x), Float(boundary[i].y), z)
            let next = boundary[(i + 1) % boundary.count]
            let nextVertex = Position3(Float(next.x), Float(next.y), z)
            positions.append(contentsOf: [centerVertex, current, nextVertex])
            colors.append(contentsOf: [color, color, color])
        }
    }

    // MARK: - Grid line construction

    /// Builds all three possible grid crosshatch planes (XY/XZ/YZ), one per possible *excluded*
    /// axis -- see this class's own top comment for why only one is ever drawn per frame. Each
    /// plane's own "fixed" coordinate (the position along its excluded axis) is that axis's own
    /// grid-line midpoint -- e.g. the XY plane (excluding Z) sits at the board's Z mid-thickness,
    /// not its top -- a plain, consistent choice across all three planes rather than special-casing
    /// one of them.
    private func rebuildGridBuffers() {
        guard let device, let preview else {
            gridPlaneExcludingX = LineBuffer()
            gridPlaneExcludingY = LineBuffer()
            gridPlaneExcludingZ = LineBuffer()
            return
        }
        let xLines = preview.gridLinesX.map { Float(truncating: $0) }
        let yLines = preview.gridLinesY.map { Float(truncating: $0) }
        let zLines = preview.gridLinesZ.map { Float(truncating: $0) }
        let pmlXMin = Float(preview.pmlInnerXMin)
        let pmlXMax = Float(preview.pmlInnerXMax)
        let pmlYMin = Float(preview.pmlInnerYMin)
        let pmlYMax = Float(preview.pmlInnerYMax)
        let pmlZMin = Float(preview.pmlInnerZMin)
        let pmlZMax = Float(preview.pmlInnerZMax)

        func midpoint(_ values: [Float]) -> Float {
            guard let lo = values.min(), let hi = values.max() else { return 0 }
            return (lo + hi) / 2
        }

        let xy = Self.buildPlaneGrid(valuesA: xLines, valuesB: yLines, fixedC: midpoint(zLines),
                                       pmlAMin: pmlXMin, pmlAMax: pmlXMax, pmlBMin: pmlYMin, pmlBMax: pmlYMax) { a, b, c in
            Position3(a, b, c)
        }
        let xz = Self.buildPlaneGrid(valuesA: xLines, valuesB: zLines, fixedC: midpoint(yLines),
                                       pmlAMin: pmlXMin, pmlAMax: pmlXMax, pmlBMin: pmlZMin, pmlBMax: pmlZMax) { a, b, c in
            Position3(a, c, b) // a=X, b=Z, c=Y
        }
        let yz = Self.buildPlaneGrid(valuesA: yLines, valuesB: zLines, fixedC: midpoint(xLines),
                                       pmlAMin: pmlYMin, pmlAMax: pmlYMax, pmlBMin: pmlZMin, pmlBMax: pmlZMax) { a, b, c in
            Position3(c, a, b) // a=Y, b=Z, c=X
        }
        gridPlaneExcludingZ = Self.makeLineBuffer(device: device, positions: xy.positions, colors: xy.colors)
        gridPlaneExcludingY = Self.makeLineBuffer(device: device, positions: xz.positions, colors: xz.colors)
        gridPlaneExcludingX = Self.makeLineBuffer(device: device, positions: yz.positions, colors: yz.colors)
    }

    /// One plane's worth of crosshatch grid lines: every `valuesA` position as one line spanning
    /// `valuesB`'s own full range, and vice versa -- spanning the *grid's own* domain on the axis a
    /// line doesn't run parallel to, not the sliced board's own (much smaller) bounding box (the
    /// FDTD domain extends well past the board itself, PML band included -- see the old 2D-only
    /// version of this same logic, which this generalizes to a `place` closure choosing which of
    /// X/Y/Z each of a/b/c actually is). `fixedC` is this plane's own single fixed coordinate along
    /// its excluded third axis.
    private static func buildPlaneGrid(valuesA: [Float], valuesB: [Float], fixedC: Float,
                                        pmlAMin: Float, pmlAMax: Float, pmlBMin: Float, pmlBMax: Float,
                                        place: (Float, Float, Float) -> Position3)
        -> (positions: [Position3], colors: [SIMD4<Float>]) {
        var positions: [Position3] = []
        var colors: [SIMD4<Float>] = []
        if let bMin = valuesB.min(), let bMax = valuesB.max() {
            for a in valuesA {
                let color = (a < pmlAMin || a > pmlAMax) ? pmlLineColor : gridLineColor
                positions.append(contentsOf: [place(a, bMin, fixedC), place(a, bMax, fixedC)])
                colors.append(contentsOf: [color, color])
            }
        }
        if let aMin = valuesA.min(), let aMax = valuesA.max() {
            for b in valuesB {
                let color = (b < pmlBMin || b > pmlBMax) ? pmlLineColor : gridLineColor
                positions.append(contentsOf: [place(aMin, b, fixedC), place(aMax, b, fixedC)])
                colors.append(contentsOf: [color, color])
            }
        }
        return (positions, colors)
    }

    private static func makeLineBuffer(device: MTLDevice, positions: [Position3], colors: [SIMD4<Float>]) -> LineBuffer {
        LineBuffer(positionBuffer: positions.isEmpty ? nil : device.makeBuffer(
                       bytes: positions, length: MemoryLayout<Position3>.stride * positions.count),
                   colorBuffer: colors.isEmpty ? nil : device.makeBuffer(
                       bytes: colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count),
                   vertexCount: positions.count)
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
    /// EMSSimulationPipelineBridge's own libkicad_query::layerColors() call resolves to when nothing
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
