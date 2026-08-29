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
/// Camera: an orbit camera (mouse-drag rotate, right-drag pan, scroll/magnify zoom -- rotate/zoom
/// match FieldView's own interaction, sharing its camera math via Board3DMath.swift; pan is
/// GeometryView-only, FieldView has no pan) but *orthographic*, not perspective,
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
            selectedGridLayerIndex = nil
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
        didSet {
            rebuildLegend()
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private var commandQueue: MTLCommandQueue!
    private var opaquePipelineState: MTLRenderPipelineState!
    /// Real depth test *and* write -- unlike FieldView's own translucent overlay/voxel passes
    /// (which can't use a real depth test at all, see paintersDepthStencilState's own doc comment
    /// there), every *opaque* draw in this view is fully opaque, so a standard depth-tested
    /// pipeline handles occlusion correctly regardless of submission order -- no per-frame
    /// back-to-front layer sorting needed here the way FieldView's own board-reference render still
    /// requires. The exceptions are the always-visible grid overlay and solder mask (see their
    /// dedicated states below).
    private var depthStencilState: MTLDepthStencilState!
    /// Grid lines are a diagnostic overlay, not board geometry: they should remain visible through
    /// the board instead of being clipped by whichever surface happens to be in front of their
    /// crosshatch plane. They neither test nor write depth.
    private var gridDepthStencilState: MTLDepthStencilState!
    /// Solder mask alone renders translucent (50% opacity, so the copper/silkscreen underneath
    /// stays visible -- matching FieldView's own board-reference treatment), unlike every other
    /// opaque draw in this view -- same "field_overlay_vertex/fragment" shader pair and blend
    /// descriptor FieldView's own overlayPipelineState already uses, just reused here for one more
    /// draw call rather than this view's whole scene.
    private var translucentPipelineState: MTLRenderPipelineState!
    /// Real depth *test* (so the mask is correctly hidden by opaque geometry in front of it, e.g.
    /// viewed from the board's own far side) but no depth *write* -- standard for a translucent
    /// draw, though with only one translucent layer per side here it's mostly a safety default
    /// matching FieldView's own paintersDepthStencilState reasoning rather than something this
    /// view's own single mask draw strictly depends on yet.
    private var translucentDepthStencilState: MTLDepthStencilState!

    // MARK: - Board geometry (layers + vias + ports, one combined opaque triangle buffer)

    private var boardPositionBuffer: MTLBuffer?
    private var boardColorBuffer: MTLBuffer?
    private var boardVertexCount = 0

    // MARK: - Solder mask (translucent, drawn in its own pass after every opaque draw above)

    private var maskPositionBuffer: MTLBuffer?
    private var maskColorBuffer: MTLBuffer?
    private var maskVertexCount = 0

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
    private var selectedGridLayerIndex: Int?
    private var selectedGridLayerBuffer = LineBuffer()

    // MARK: - Orbit camera

    private static let isometricElevation: Float = atan(1 / Float(2).squareRoot())
    /// Drag state is still plain azimuth/elevation (not a quaternion accumulated incrementally
    /// drag-over-drag) -- an earlier version composed each drag directly onto a stored quaternion
    /// (yaw around world Z, pitch around the camera's own current right axis), which in principle
    /// avoids gimbal lock the same way this does, but felt visibly wrong in practice (left/right
    /// drag behaved like it was rolling around the view direction rather than yawing around world
    /// up -- never fully root-caused). Keeping azimuth/elevation as the actual state sidesteps
    /// whatever that was: the drag math below is untouched from the original Euler-angle camera,
    /// just without its elevation clamp. What *does* change is how the camera's basis vectors are
    /// derived -- currentOrientation() builds a fresh quaternion from the angles every frame (see
    /// its own doc comment for why that, unlike reconstructing eye/right/up from raw sin/cos and a
    /// fixed world-up cross product, never degenerates at the poles) -- so azimuth/elevation can
    /// range freely with no clamp, while the actual rotation composition that seemed to be the
    /// problem never happens.
    private var azimuth: Float = -.pi / 4
    private var elevation: Float = GeometryView.isometricElevation
    private var distance: Float = 1
    private var target = Position3(0, 0, 0)
    private var sceneRadius: Float = 1
    private var hasFitCamera = false
    private var lastDragPoint: CGPoint?
    private var lastPanDragPoint: CGPoint?

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
            opaquePipelineState = Self.makePipelineState(device: device, pixelFormat: colorPixelFormat, translucent: false)
            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)

            let gridDepthDescriptor = MTLDepthStencilDescriptor()
            gridDepthDescriptor.depthCompareFunction = .always
            gridDepthDescriptor.isDepthWriteEnabled = false
            gridDepthStencilState = device.makeDepthStencilState(descriptor: gridDepthDescriptor)

            translucentPipelineState = Self.makePipelineState(device: device, pixelFormat: colorPixelFormat, translucent: true)
            let translucentDepthDescriptor = MTLDepthStencilDescriptor()
            translucentDepthDescriptor.depthCompareFunction = .less
            translucentDepthDescriptor.isDepthWriteEnabled = false
            translucentDepthStencilState = device.makeDepthStencilState(descriptor: translucentDepthDescriptor)
        }

        setupLegend()
    }

    /// Reuses FieldShaders.metal's own `field_overlay_vertex`/`field_overlay_fragment` -- the same
    /// "positions + colors + one view-projection uniform" shader pair FieldView's own board
    /// reference render uses (see this view's own top comment: requirement 1 is to reuse that same
    /// 3D board-drawing code, not reimplement it). `translucent` reuses the exact same standard
    /// "over" alpha-blend descriptor FieldView's own makePipelineState() sets up for its overlay --
    /// every draw in this view is opaque *except* solder mask (see translucentPipelineState's own
    /// doc comment), which needs its own separately-blended pipeline state.
    private static func makePipelineState(device: MTLDevice, pixelFormat: MTLPixelFormat,
                                           translucent: Bool) -> MTLRenderPipelineState? {
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
        if translucent {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue, let opaquePipelineState, let depthStencilState, let gridDepthStencilState,
              let drawable = currentDrawable, let descriptor = currentRenderPassDescriptor else { return }
        resetCameraIfNeeded()

        descriptor.colorAttachments[0].clearColor = Self.backgroundColor
        descriptor.depthAttachment.clearDepth = 1.0

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var uniforms = FieldUniformsGPU(viewProjection: currentProjectionMatrix() * lookAt(
            eye: currentEyePosition(), center: SIMD3(target.x, target.y, target.z),
            up: -currentOrientation().act(SIMD3<Float>(1, 0, 0))))

        encoder.setRenderPipelineState(opaquePipelineState)
        encoder.setDepthStencilState(depthStencilState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 2)

        // Real depth test/write for opaque board geometry (see depthStencilState's own doc comment)
        // -- draw order below doesn't affect its correctness. The diagnostic grid switches to its
        // own depth-free overlay state immediately before it is drawn.
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
                encoder.setDepthStencilState(gridDepthStencilState)
                encoder.setVertexBuffer(positions, offset: 0, index: 0)
                encoder.setVertexBuffer(colors, offset: 0, index: 1)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: activeGrid.vertexCount)
            }
        }

        // Solder mask, translucent, drawn last -- see translucentPipelineState's own doc comment.
        // Depth-tested against everything opaque drawn above (so it's correctly hidden when viewed
        // from the board's own far side), just with its own separately-blended pipeline state.
        if maskVertexCount > 0, let positions = maskPositionBuffer, let colors = maskColorBuffer,
           let translucentPipelineState, let translucentDepthStencilState {
            encoder.setRenderPipelineState(translucentPipelineState)
            encoder.setDepthStencilState(translucentDepthStencilState)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: maskVertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Camera math

    /// Builds this frame's camera-orientation quaternion fresh from azimuth/elevation, rather than
    /// storing/accumulating one across drags (see azimuth's own doc comment for why). Equivalent to
    /// the old raw-trig eye-position formula (cos(el)cos(az), cos(el)sin(az), sin(el)) when acting
    /// on local +Z, but *also* gives a well-defined right/up anywhere -- including exactly at the
    /// poles, where the old cross(forward, worldUp)-based approach degenerated (cross product of
    /// two parallel vectors is zero) and had to be papered over with an elevation clamp. Order:
    /// first tilt local +Z down from straight-up by (90-elevation) around Y, then yaw the result
    /// around Z by azimuth -- chosen so that acting on local +Z reproduces the old formula exactly.
    ///
    /// Acting on local +X/+Y does *not* give azimuthal-right/elevation-up directly, though -- this
    /// construction's own local +Y stays fixed at the *azimuthal* tangent direction regardless of
    /// elevation (Ry(90-el) leaves the Y axis it rotates around unchanged, so only the later Rz(az)
    /// yaw ever moves it), while local +X ends up at the *negated* elevation tangent. Confirmed
    /// numerically (not just by inspection -- this is exactly the kind of thing worth double-
    /// checking with actual numbers, not re-deriving by hand again) before fixing what was, for one
    /// commit, a real right/up mixup: dragging left/right visibly rolled the view around the camera's
    /// own forward axis instead of yawing around world up. See cameraRightAndUp()/draw(in:)'s own
    /// `up:` argument, which read local +X/+Y directly and hit exactly that bug.
    private func currentOrientation() -> simd_quatf {
        simd_quatf(angle: azimuth, axis: SIMD3<Float>(0, 0, 1)) *
            simd_quatf(angle: .pi / 2 - elevation, axis: SIMD3<Float>(0, 1, 0))
    }

    private func currentEyePosition() -> SIMD3<Float> {
        let eyeOffset = currentOrientation().act(SIMD3<Float>(0, 0, 1))
        return SIMD3<Float>(target.x, target.y, target.z) + distance * eyeOffset
    }

    /// Unit vector from `target` toward the camera -- used only to decide which world axis is most
    /// aligned with the current view direction (see mostAlignedAxis()), so grid lines can be drawn
    /// for the other two (see this class's own top comment).
    private func eyeOffsetDirection() -> SIMD3<Float> {
        currentOrientation().act(SIMD3<Float>(0, 0, 1))
    }

    private enum Axis3 { case x, y, z }

    private func mostAlignedAxis() -> Axis3 {
        let f = eyeOffsetDirection()
        let ax = abs(f.x), ay = abs(f.y), az = abs(f.z)
        if ax >= ay, ax >= az { return .x }
        if ay >= az { return .y }
        return .z
    }

    /// The camera's own current right/up basis vectors (screen-space horizontal/vertical, in world
    /// coordinates), read directly off currentOrientation() -- exactly the same up passed to
    /// lookAt() in draw(in:), so panning shifts `target` along axes that actually match what's on
    /// screen. See currentOrientation()'s own doc comment for why right/up come from local +Y and
    /// *negated* local +X, not the more intuitive-looking local +X/+Y.
    private func cameraRightAndUp() -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let o = currentOrientation()
        return (o.act(SIMD3<Float>(0, 1, 0)), -o.act(SIMD3<Float>(1, 0, 0)))
    }

    private func gridPlane(excluding axis: Axis3) -> LineBuffer {
        if selectedGridLayerIndex != nil {
            return selectedGridLayerBuffer
        }
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

    /// Orbit: drag left/right to rotate azimuth, up/down to tilt elevation -- see azimuth's own doc
    /// comment for why this is unclamped (no gimbal lock) despite being plain Euler angles. Right-
    /// drag pans instead (see rightMouseDragged(_:)), shifting the orbit target itself rather than
    /// orbiting around it.
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
        elevation += dy * sensitivity
        self.lastDragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    /// Pan: shifts `target` (the orbit center) along the camera's own current right/up axes, scaled
    /// by the orthographic view's own world-units-per-screen-point ratio so the point under the
    /// cursor at drag start stays under the cursor throughout the drag (a "grab and drag" feel,
    /// matching Photoshop's hand tool/Google Maps -- not a fixed, zoom-independent speed).
    override func rightMouseDown(with event: NSEvent) {
        lastPanDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let lastPanDragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastPanDragPoint.x)
        let dy = Float(point.y - lastPanDragPoint.y)
        self.lastPanDragPoint = point

        let worldPerPoint = (distance * 0.8) / Float(max(bounds.height, 1))
        let (right, up) = cameraRightAndUp()
        target.x -= (right.x * dx + up.x * dy) * worldPerPoint
        target.y -= (right.y * dx + up.y * dy) * worldPerPoint
        target.z -= (right.z * dx + up.z * dy) * worldPerPoint
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        lastPanDragPoint = nil
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
    private static let portColor = SIMD4<Float>(Float(NSColor.systemBlue.usingColorSpace(.deviceRGB)?.redComponent ?? 0.2),
                                                  Float(NSColor.systemBlue.usingColorSpace(.deviceRGB)?.greenComponent ?? 0.48),
                                                  Float(NSColor.systemBlue.usingColorSpace(.deviceRGB)?.blueComponent ?? 0.98),
                                                  1)
    // A fixed light grey, not the adaptive tertiaryLabelColor the outline used to use -- that
    // reads as near-invisible against the fixed dark canvas below in light-appearance mode.
    private static let outlineColor = SIMD4<Float>(0.7, 0.7, 0.7, 1)
    // A classic PCB solder-mask green -- distinct from every copper color in kicadDefaultLayerColors
    // (all coppery/metallic tones) so the mask reads as its own material, not another copper layer.
    // 50% alpha (drawn via translucentPipelineState, not the opaque one every other color here
    // uses) so the copper/silkscreen underneath stays visible, matching a real solder mask's own
    // partial translucency.
    private static let solderMaskColor = SIMD4<Float>(0.0, 0.35, 0.16, 0.5)
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
            maskVertexCount = 0
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

        // Solder mask, if this board's stackup has one on that side (see EMSGeometryPreview.
        // topSolderMask/bottomSolderMask's own doc comment) -- built into its own separate buffer,
        // drawn in draw(in:)'s own translucent pass after everything above, rather than appended
        // into this opaque positions/colors pair like every other element in this loop.
        var maskPositions: [Position3] = []
        var maskColors: [SIMD4<Float>] = []
        for maskLayer in [preview.topSolderMask, preview.bottomSolderMask].compactMap({ $0 }) {
            let z = Float(maskLayer.z)
            for triangle in maskLayer.triangles {
                maskPositions.append(contentsOf: [Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                                                   Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                                                   Position3(Float(triangle.c.x), Float(triangle.c.y), z)])
                maskColors.append(contentsOf: [Self.solderMaskColor, Self.solderMaskColor, Self.solderMaskColor])
            }
        }
        maskVertexCount = maskPositions.count
        maskPositionBuffer = maskPositions.isEmpty ? nil : device.makeBuffer(
            bytes: maskPositions, length: MemoryLayout<Position3>.stride * maskPositions.count)
        maskColorBuffer = maskColors.isEmpty ? nil : device.makeBuffer(
            bytes: maskColors, length: MemoryLayout<SIMD4<Float>>.stride * maskColors.count)

        // Real 3D via geometry (open barrel tube + per-layer annular rings -- see
        // EMSGeometryPreview.viaMeshTriangles' own doc comment) -- replaces the old flat, single-Z
        // concentric-capsule marker this used to draw here: that read fine from the old fixed
        // top-down 2D view, but from any angle a real 3D camera can now reach, three flat discs
        // floating at one Z (and copper layers with no hole cut for them to sit in) just look wrong.
        // Each vertex keeps its own real Z, same as componentMeshTriangles below, not a shared flat
        // markerZ.
        for triangle in preview.viaMeshTriangles {
            positions.append(contentsOf: [
                Position3(Float(triangle.a.x), Float(triangle.a.y), Float(triangle.a.z)),
                Position3(Float(triangle.b.x), Float(triangle.b.y), Float(triangle.b.z)),
                Position3(Float(triangle.c.x), Float(triangle.c.y), Float(triangle.c.z)),
            ])
            let color = SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y), Float(triangle.color.z),
                                       Float(triangle.color.w))
            colors.append(contentsOf: [color, color, color])
        }

        for port in preview.ports {
            let radius = max(CGFloat(port.width) / 2, 1)
            Self.appendDisc(center: port.position, radius: radius, z: markerZ, color: Self.portColor,
                             positions: &positions, colors: &colors)
        }

        // Real 3D models of every included footprint (see EMSGeometryComponentTriangle's own doc
        // comment) -- unlike every other marker here, each vertex keeps its own real Z from the
        // mesh (a component has genuine 3D shape), not a shared flat markerZ. Color is the model's
        // own real STEP color (see EMSGeometryComponentTriangle.color's own doc comment), not the
        // fixed accent color used everywhere else in this view -- STL (which carries no color data)
        // is no longer what these come from.
        for triangle in preview.componentMeshTriangles {
            positions.append(contentsOf: [
                Position3(Float(triangle.a.x), Float(triangle.a.y), Float(triangle.a.z)),
                Position3(Float(triangle.b.x), Float(triangle.b.y), Float(triangle.b.z)),
                Position3(Float(triangle.c.x), Float(triangle.c.y), Float(triangle.c.z)),
            ])
            let color = SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y), Float(triangle.color.z),
                                       Float(triangle.color.w))
            colors.append(contentsOf: [color, color, color])
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
        if let excludingX = preview.gridPlaneExcludingX,
           let excludingY = preview.gridPlaneExcludingY,
           let excludingZ = preview.gridPlaneExcludingZ {
            gridPlaneExcludingX = Self.makeLineBuffer(device: device, plane: excludingX)
            gridPlaneExcludingY = Self.makeLineBuffer(device: device, plane: excludingY)
            gridPlaneExcludingZ = Self.makeLineBuffer(device: device, plane: excludingZ)
            rebuildSelectedGridLayerBuffer()
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
        rebuildSelectedGridLayerBuffer()
    }

    private func rebuildSelectedGridLayerBuffer() {
        guard let device, let preview, let index = selectedGridLayerIndex,
              preview.gridLayers.indices.contains(index) else {
            selectedGridLayerBuffer = LineBuffer()
            return
        }
        let layer = preview.gridLayers[index]
        let xLines = preview.gridLinesX.map { Float(truncating: $0) }
        let yLines = preview.gridLinesY.map { Float(truncating: $0) }
        guard !xLines.isEmpty, !yLines.isEmpty else {
            selectedGridLayerBuffer = LineBuffer()
            return
        }
        let edgeCount = (xLines.count - 1) * yLines.count + xLines.count * (yLines.count - 1)
        guard layer.edgeColors.count == edgeCount * MemoryLayout<SIMD4<Float>>.stride else {
            selectedGridLayerBuffer = LineBuffer()
            return
        }
        var edgeColors = Array(repeating: SIMD4<Float>(repeating: 0), count: edgeCount)
        _ = edgeColors.withUnsafeMutableBytes { destination in
            layer.edgeColors.copyBytes(to: destination)
        }
        var positions: [Position3] = []
        var colors: [SIMD4<Float>] = []
        positions.reserveCapacity(edgeCount * 2)
        colors.reserveCapacity(edgeCount * 2)
        let z = Float(layer.z)
        var edge = 0
        for y in yLines {
            for x in 0..<(xLines.count - 1) {
                positions.append(contentsOf: [Position3(xLines[x], y, z), Position3(xLines[x + 1], y, z)])
                colors.append(contentsOf: [edgeColors[edge], edgeColors[edge]])
                edge += 1
            }
        }
        for x in xLines {
            for y in 0..<(yLines.count - 1) {
                positions.append(contentsOf: [Position3(x, yLines[y], z), Position3(x, yLines[y + 1], z)])
                colors.append(contentsOf: [edgeColors[edge], edgeColors[edge]])
                edge += 1
            }
        }
        selectedGridLayerBuffer = Self.makeLineBuffer(device: device, positions: positions, colors: colors)
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

    private static func makeLineBuffer(device: MTLDevice, plane: EMSGeometryGridPlane) -> LineBuffer {
        let positions = plane.positions
        let colors = plane.colors
        let vertexCount = Int(plane.vertexCount)
        guard vertexCount > 0,
              positions.count == vertexCount * MemoryLayout<Position3>.stride,
              colors.count == vertexCount * MemoryLayout<SIMD4<Float>>.stride else {
            return LineBuffer()
        }
        let positionBuffer = positions.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        }
        let colorBuffer = colors.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
        }
        return LineBuffer(positionBuffer: positionBuffer, colorBuffer: colorBuffer, vertexCount: vertexCount)
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
        guard let preview else { return }
        for (index, layer) in preview.layers.enumerated() {
            let swatch = NSBox()
            swatch.boxType = .custom // No border by default for .custom (unlike the legacy box types borderType controls).
            swatch.fillColor = Self.color(for: layer, index: index, total: preview.layers.count)
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
        if showGrid {
            if !preview.gridLayers.isEmpty {
                let title = NSTextField(labelWithString: "Grid layer:")
                title.font = .systemFont(ofSize: 11)
                title.textColor = .white
                let popUp = NSPopUpButton()
                popUp.appearance = NSAppearance(named: .darkAqua)
                popUp.addItem(withTitle: "Automatic cross-section")
                preview.gridLayers.forEach { popUp.addItem(withTitle: $0.name) }
                popUp.selectItem(at: (selectedGridLayerIndex ?? -1) + 1)
                popUp.target = self
                popUp.action = #selector(selectGridLayer(_:))
                let row = NSStackView(views: [title, popUp])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 6
                legendStack.addArrangedSubview(row)
            }
            for material in preview.gridMaterials {
                let swatch = NSBox()
                swatch.boxType = .custom
                swatch.fillColor = NSColor(deviceRed: material.color.x, green: material.color.y,
                                           blue: material.color.z, alpha: material.color.w)
                swatch.translatesAutoresizingMaskIntoConstraints = false
                swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
                swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true

                let label = NSTextField(labelWithString: "Grid: \(material.name)")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .white
                let row = NSStackView(views: [swatch, label])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 6
                legendStack.addArrangedSubview(row)
            }
        }
    }

    @objc private func selectGridLayer(_ sender: NSPopUpButton) {
        selectedGridLayerIndex = sender.indexOfSelectedItem == 0 ? nil : sender.indexOfSelectedItem - 1
        rebuildSelectedGridLayerBuffer()
        needsDisplay = true
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
