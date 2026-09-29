import Cocoa
import CopperUtils
import MetalKit
import RememberRemember
import simd

/// Renders an EMSFieldSnapshot (the field/energy state Copper captured at the end of a completed
/// GPU FDTD run) as a 3D voxel cloud, plus the same board geometry the Geometry tab shows -- laid
/// out flat at the board's own top Z, at 50% opacity -- as a spatial reference underneath it. Real
/// perspective camera (unlike GeometryView's orthographic one -- see FieldShaders.metal's own top
/// comment for why this needs its own shader pair), with the same mouse-drag orbit/right-drag pan/
/// scroll-zoom interaction.
final class FieldView: MTKView, MTKViewDelegate {
    private var isReplacingSnapshot = false
    var preview: EMSGeometryPreview? {
        didSet {
            rebuildOverlayBuffers()
            // geometryPreview() on the pipeline side caches and returns the same instance until
            // something actually invalidates it, so identity here reliably means "unchanged" --
            // see fieldSnapshot's own didSet for why that distinction matters (this mirrors it).
            if oldValue !== preview {
                hasFitCamera = false
            }
            needsDisplay = true
        }
    }

    private(set) var fieldSnapshot: EMSFieldSnapshot? {
        didSet {
            let frameCount = fieldSnapshot?.frames.count ?? 0
            currentFrameIndex = frameCount > 0 ? min(currentFrameIndex, frameCount - 1) : 0
            // A live SWMR refresh hands back a brand-new EMSFieldSnapshot object for the *same*
            // series (same simulationName+excitedPort, just with more frames published) on every
            // progress tick, even though it now reuses the same underlying reader/decode cache
            // rather than reopening it -- see buildFieldSnapshot()'s own doc comment. Re-fitting the
            // camera on every one of those ticks would silently reset the zoom/pan out from under
            // whoever's currently inspecting the view. Preserve the normalization peak accumulated
            // from frames already played for a same-series refresh, and reset it only for a genuinely
            // different series.
            if !Self.isSameSeries(oldValue, fieldSnapshot) {
                oldValue?.discardCachedFrameData()
                hasFitCamera = false
                seriesOnBoardMaxEnergy = 0
            }
            rebuildVoxelGeometry()
            needsDisplay = true
            startRefinementCycle()
        }
    }

    private static func isSameSeries(_ a: EMSFieldSnapshot?, _ b: EMSFieldSnapshot?) -> Bool {
        guard let a, let b else { return false }
        return a.simulationName == b.simulationName && a.excitedPort == b.excitedPort
    }

    /// Which of `fieldSnapshot.frames` the voxel cloud currently displays -- see
    /// rebuildVoxelGeometry()/updateVoxelColors(forFrame:)'s own doc comments for why changing this
    /// only rebuilds the (cheap) per-frame color buffer, not the full cell geometry. Clamped to the
    /// current snapshot's own frame count; left at whatever it was across a snapshot change unless
    /// that would now be out of range (see fieldSnapshot's own didSet).
    var currentFrameIndex: Int = 0 {
        didSet {
            guard !isReplacingSnapshot, currentFrameIndex != oldValue else { return }
            // Prepared playback frames may contain a different set of adaptively refined cells, so
            // their instance geometry changes as well as their colours. Cold scrubbing still takes
            // the cheap all-preview path inside rebuildVoxelGeometry().
            rebuildVoxelGeometry()
            needsDisplay = true
            startRefinementCycle()
        }
    }

    private static let playbackDecodeBudget: TimeInterval = 0.1
    private var refinementGeneration = 0
    private var playbackIsActive = false
    private var refinementIsEnabled = false

    /// Enables background refinement only while this pane is visible. This is separate from
    /// playback state: a paused, visible viewer deliberately keeps improving the next frame and
    /// then the displayed frame, while a hidden viewer must do no field decoding at all.
    func setRefinementEnabled(_ enabled: Bool) {
        guard refinementIsEnabled != enabled else { return }
        refinementIsEnabled = enabled
        startRefinementCycle()
    }

    /// Switches between the bounded per-playback-frame decode budget and paused exhaustive
    /// refinement. Changing this generation makes callbacks from the old policy harmless; the
    /// underlying decode is bounded to one short chunk, so Play responds promptly even if pressed
    /// while paused refinement is in flight.
    func setPlaybackActive(_ active: Bool) {
        guard playbackIsActive != active else { return }
        playbackIsActive = active
        startRefinementCycle()
    }

    private func startRefinementCycle() {
        refinementGeneration += 1
        let generation = refinementGeneration
        guard refinementIsEnabled, let frames = fieldSnapshot?.frames,
              frames.indices.contains(currentFrameIndex) else { return }
        if playbackIsActive {
            refineDuringPlayback(frames: frames, generation: generation)
        } else {
            refineWhilePaused(frames: frames, generation: generation)
        }
    }

    /// Playback first spends the frame's 100 ms residency on its successor. If that successor is
    /// already complete (or finishes early), the remaining wall-clock budget refines the frame
    /// currently on screen. The playback timer and decoder use the same interval, so decoding can
    /// never deliberately make the displayed frame overrun its target residency.
    private func refineDuringPlayback(frames: [EMSFieldFrame], generation: Int) {
        let deadline = Date().addingTimeInterval(Self.playbackDecodeBudget)
        let nextIndex = min(currentFrameIndex + 1, frames.count - 1)
        let currentIndex = currentFrameIndex

        func refineCurrentWithRemainingBudget() {
            guard refinementCycleIsCurrent(generation, frameIndex: currentIndex),
                  playbackIsActive else { return }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            frames[currentIndex].prepare(withBudget: remaining) { [weak self] _ in
                self?.displayNewRefinement(generation: generation, frameIndex: currentIndex)
            }
        }

        guard nextIndex != currentIndex else {
            refineCurrentWithRemainingBudget()
            return
        }
        frames[nextIndex].prepare(withBudget: Self.playbackDecodeBudget) { [weak self] complete in
            guard let self, self.refinementCycleIsCurrent(generation, frameIndex: currentIndex),
                  self.playbackIsActive, complete else { return }
            refineCurrentWithRemainingBudget()
        }
    }

    /// While paused there is no presentation deadline. Decode in short chunks so Play can change
    /// policy promptly: finish the successor first, then continue the displayed frame until every
    /// detail tile is present. Each current-frame chunk is installed immediately so the stationary
    /// image visibly sharpens rather than changing only after the entire frame has decoded.
    private func refineWhilePaused(frames: [EMSFieldFrame], generation: Int) {
        let currentIndex = currentFrameIndex
        let nextIndex = min(currentIndex + 1, frames.count - 1)
        func refineCurrent() {
            refineUntilComplete(frames: frames, frameIndex: currentIndex, generation: generation,
                                redrawCurrent: true, completion: {})
        }
        guard nextIndex != currentIndex else {
            refineCurrent()
            return
        }
        refineUntilComplete(frames: frames, frameIndex: nextIndex, generation: generation,
                            redrawCurrent: false, completion: refineCurrent)
    }

    private func refineUntilComplete(frames: [EMSFieldFrame], frameIndex: Int, generation: Int,
                                     redrawCurrent: Bool, completion: @escaping () -> Void) {
        guard refinementCycleIsCurrent(generation, frameIndex: currentFrameIndex),
              !playbackIsActive else { return }
        frames[frameIndex].prepare(withBudget: Self.playbackDecodeBudget) { [weak self] complete in
            guard let self,
                  self.refinementCycleIsCurrent(generation, frameIndex: self.currentFrameIndex),
                  !self.playbackIsActive else { return }
            if redrawCurrent {
                self.displayNewRefinement(generation: generation, frameIndex: frameIndex)
            }
            if complete {
                completion()
            } else {
                self.refineUntilComplete(frames: frames, frameIndex: frameIndex,
                                         generation: generation, redrawCurrent: redrawCurrent,
                                         completion: completion)
            }
        }
    }

    private func refinementCycleIsCurrent(_ generation: Int, frameIndex: Int) -> Bool {
        refinementIsEnabled && refinementGeneration == generation && currentFrameIndex == frameIndex
    }

    private func displayNewRefinement(generation: Int, frameIndex: Int) {
        guard refinementCycleIsCurrent(generation, frameIndex: frameIndex) else { return }
        rebuildVoxelGeometry()
        needsDisplay = true
    }

    /// Replaces the series and chooses its initial frame as one atomic viewer operation. Setting the
    /// two properties independently can briefly read a frame from the old series before the new
    /// snapshot arrives; this suppresses that intermediate read and rebuilds once at `frameIndex`.
    func show(snapshot: EMSFieldSnapshot, frameIndex: Int) {
        let count = snapshot.frames.count
        let clampedIndex = count > 0 ? min(max(frameIndex, 0), count - 1) : 0
        isReplacingSnapshot = true
        currentFrameIndex = clampedIndex
        fieldSnapshot = snapshot
        isReplacingSnapshot = false
    }

    /// Drops large decoded buffers while retaining the current series/viewport so returning to the
    /// viewer can stream the selected frame again without rebuilding the surrounding UI state.
    func discardCachedFrameData() {
        refinementGeneration += 1
        fieldSnapshot?.discardCachedFrameData()
    }

    override var acceptsFirstResponder: Bool { true }

    private var commandQueue: MTLCommandQueue!
    private var overlayPipelineState: MTLRenderPipelineState!
    private var voxelPipelineState: MTLRenderPipelineState!
    /// Always-pass, no-write -- shared by both the overlay and voxel passes, which both now rely on
    /// draw-call submission order (sorted back-to-front by the current camera every frame -- see
    /// draw()'s own per-pass doc comments) rather than a real depth test. See this property's
    /// creation in commonInit() for why: a real depth *write* on translucent geometry (the voxel
    /// cloud's whole reason for existing) makes a dim, low-energy cell permanently occlude a much
    /// brighter one behind it, since a fragment that fails the depth test is discarded outright, not
    /// blended -- there's no way to get that right with a real depth test on translucent draws
    /// without a full per-fragment sort, which back-to-front *layer* submission approximates cheaply.
    private var paintersDepthStencilState: MTLDepthStencilState!

    private var overlayPositionBuffer: MTLBuffer?
    private var overlayColorBuffer: MTLBuffer?
    private var overlayVertexCount = 0
    /// One entry per copper layer, recording its own Z plane and the vertex range within
    /// overlayPositionBuffer/overlayColorBuffer that draws it -- see draw()'s own doc comment for why
    /// these are issued as separate draw calls, sorted back-to-front by the *current* camera position
    /// every frame, rather than the whole overlay being one fixed-order draw call.
    private var overlayLayerDraws: [(z: Float, start: Int, count: Int)] = []
    /// Vias/outline -- appended after every layer's own range, always drawn last/on top (a
    /// static simplification: these are thin reference markers nudged just beyond the topmost
    /// copper layer, not full-thickness fills, so getting their draw order wrong when the camera is
    /// below the board is a much smaller visual error than the layer-stack one this fixes).
    private var overlayMarkerRange: (start: Int, count: Int)?

    private var cubeVertexBuffer: MTLBuffer!
    // Split into two buffers, not one interleaved VoxelInstance array -- see FieldShaders.metal's
    // own VoxelGeometry doc comment: geometry is rebuilt only when fieldSnapshot's own mesh changes,
    // colors are rebuilt every playback frame change, and keeping them in separate buffers means a
    // frame change never has to re-walk/re-upload the (much larger) position/size data.
    private var voxelGeometryBuffer: MTLBuffer?
    private var voxelColorBuffer: MTLBuffer?
    private var voxelInstanceCount = 0

    // Cached cell-grid bounds from the last rebuildVoxelGeometry() call, in the exact iteration
    // order that built voxelGeometryBuffer -- reused by updateVoxelColors(forFrame:) so it can walk
    // the identical (ix, iy, iz) sequence without needing to store an explicit index per instance.
    private var voxelCachedNx = 0
    private var voxelCachedNy = 0
    private var voxelCachedZRange: ClosedRange<Int>?
    /// Preview-energy index for each geometry instance. Normally one preview voxel maps to one
    /// value; boundary-straddling preview voxels are split into active full-resolution XY cells,
    /// all sharing the preview value, while external children are omitted entirely.
    private var voxelCachedEnergyIndices: [Int] = []
    /// The color scale's peak for the currently-displayed frame -- now always equal to
    /// seriesOnBoardMaxEnergy (see its own doc comment), not that one frame's own peak.
    private var voxelCachedMaxEnergy: Float = 0

    /// The on-board (voxelCachedZRange-restricted -- excludes the PML-dominated margin) energy peak
    /// across frames displayed so far. Each frame extends this value as it streams in; the viewer no
    /// longer decodes the whole series up front merely to choose a scale. Sequential playback still
    /// makes a decaying signal visibly fade instead of renormalizing every frame to full brightness.
    private var seriesOnBoardMaxEnergy: Float = 0
    /// One entry per included Z layer, recording its own center Z and the instance range (within
    /// voxelGeometryBuffer/voxelColorBuffer) that draws it -- see draw()'s own doc comment for why
    /// these are issued as separate draw calls, sorted back-to-front by the current camera each
    /// frame, the same painter's-algorithm-fix already applied to the overlay's own copper layers.
    /// Cheap because a full per-instance sort isn't needed: sorting whole Z layers (a few dozen at
    /// most) gets correct blending order for every cell *within* a layer for free (they share a Z),
    /// and is wrong only across layers when the camera is close to edge-on to the board -- an
    /// accepted approximation, not a concern for the board-inspection angles this view is meant for.
    private var voxelZLayerDraws: [(z: Float, instanceStart: Int, instanceCount: Int)] = []
    // TEMPORARY: gates draw()'s own one-shot diagnostic print -- see this file's own top comment on
    // why the voxel cloud is reportedly not rendering at all right now.
    private var hasLoggedVoxelDraw = false

    // MARK: - Orbit camera

    /// Drag state is plain azimuth/elevation (not a quaternion accumulated incrementally
    /// drag-over-drag) -- an earlier version composed each drag directly onto a stored quaternion
    /// (yaw around world Z, pitch around the camera's own current right axis), which in principle
    /// avoids gimbal lock the same way this does, but felt visibly wrong in practice (left/right
    /// drag behaved like it was rolling around the view direction rather than yawing around world
    /// up -- never fully root-caused; see GeometryView's own matching camera for the same fix).
    /// Keeping azimuth/elevation as the actual state sidesteps whatever that was: the drag math
    /// below is untouched from the original Euler-angle camera, just without its elevation clamp.
    /// What *does* change is how the camera's basis vectors are derived -- currentOrientation()
    /// builds a fresh quaternion from the angles every frame (see its own doc comment for why that
    /// never degenerates at the poles, unlike reconstructing eye/right/up from raw sin/cos and a
    /// fixed world-up cross product) -- so azimuth/elevation can range freely with no clamp. Z is
    /// still treated as "up" (the board lies flat in the XY plane, Z is its own thin thickness axis
    /// -- see EMSFieldSnapshot's own doc comment on the frame).
    private var azimuth: Float = -.pi / 4
    private var elevation: Float = .pi / 5
    private var distance: Float = 1
    private var target = Position3(0, 0, 0)
    // The scene's own bounding-sphere radius (half the fitted bounding box's diagonal), used to
    // keep the projection's near/far planes tight around the actual content -- see
    // currentProjectionMatrix()'s own doc comment for why a fixed distance-relative ratio caused
    // severe z-fighting.
    private var sceneRadius: Float = 1
    private var hasFitCamera = false

    private var lastDragPoint: CGPoint?
    private var lastPanDragPoint: CGPoint?

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
            overlayPipelineState = Self.makePipelineState(device: device, pixelFormat: colorPixelFormat,
                                                            vertexFunction: "field_overlay_vertex",
                                                            fragmentFunction: "field_overlay_fragment")
            voxelPipelineState = Self.makePipelineState(device: device, pixelFormat: colorPixelFormat,
                                                         vertexFunction: "field_voxel_vertex",
                                                         fragmentFunction: "field_voxel_fragment")
            // Always-pass, no-write -- originally added just for the overlay (a flat translucent
            // reference plane whose source triangulation of copper
            // pours/traces via GeometryPreviewBridge, isn't guaranteed to be a perfectly
            // non-overlapping planar partition, so a real depth test fought over near-identical
            // depths), now shared by the voxel pass too -- see paintersDepthStencilState's own doc
            // comment for why a real depth test/write is actively wrong for translucent voxels.
            let paintersDepthDescriptor = MTLDepthStencilDescriptor()
            paintersDepthDescriptor.depthCompareFunction = .always
            paintersDepthDescriptor.isDepthWriteEnabled = false
            paintersDepthStencilState = device.makeDepthStencilState(descriptor: paintersDepthDescriptor)
            cubeVertexBuffer = device.makeBuffer(bytes: Self.unitCubeVertices,
                                                  length: MemoryLayout<Position3>.stride * Self.unitCubeVertices.count)
        }
    }

    private static func makePipelineState(device: MTLDevice, pixelFormat: MTLPixelFormat, vertexFunction: String,
                                           fragmentFunction: String) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: vertexFunction),
              let fragment = library.makeFunction(name: fragmentFunction) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = sampleCount
        // Standard "over" alpha blending -- every draw call here is translucent (the overlay's own
        // fixed 0.5, the voxel cloud's gradient-mapped 0.25...0.75) -- see FieldView's own top
        // comment on why depth writes stay enabled anyway despite blending not being strictly
        // order-correct without per-fragment sorting: a coarse voxel cloud still reads sensibly
        // with simple z-buffering, and it's far simpler than sorting hundreds of thousands of cells
        // by camera distance every frame.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue, let drawable = currentDrawable, let descriptor = currentRenderPassDescriptor else {
            return
        }
        resetCameraIfNeeded()

        descriptor.colorAttachments[0].clearColor = Self.backgroundColor
        descriptor.depthAttachment.clearDepth = 1.0

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let eye = currentEyePosition()
        var uniforms = FieldUniformsGPU(viewProjection: currentProjectionMatrix() * lookAt(
            eye: eye, center: SIMD3(target.x, target.y, target.z), up: -currentOrientation().act(SIMD3<Float>(1, 0, 0))))

        if overlayVertexCount > 0, let positions = overlayPositionBuffer, let colors = overlayColorBuffer,
           let overlayPipelineState {
            // Always-pass, no-write depth state -- see this state's own doc comment in commonInit().
            // With no real depth test, blending is pure painter's algorithm: whichever draw call
            // happens last wins. Since the camera orbits freely, the correct submission order (each
            // copper layer's own plane, farthest from the *current* eye position first) changes every
            // frame -- issuing one draw call per layer, freshly sorted here, is what actually keeps
            // the nearer layer visually on top instead of a fixed build-time order that's only right
            // from one side (this was the bug: the deepest layer was always drawn last, painting over
            // every shallower one regardless of which side the camera was actually looking from).
            encoder.setDepthStencilState(paintersDepthStencilState)
            encoder.setRenderPipelineState(overlayPipelineState)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 2)
            let sortedLayers = eye.z >= target.z
                ? overlayLayerDraws.sorted { $0.z < $1.z } // camera above: farthest (lowest Z) first
                : overlayLayerDraws.sorted { $0.z > $1.z } // camera below: farthest (highest Z) first
            for layer in sortedLayers {
                encoder.drawPrimitives(type: .triangle, vertexStart: layer.start, vertexCount: layer.count)
            }
            if let markerRange = overlayMarkerRange {
                encoder.drawPrimitives(type: .triangle, vertexStart: markerRange.start, vertexCount: markerRange.count)
            }
        }

        if voxelInstanceCount > 0, let geometry = voxelGeometryBuffer, let colors = voxelColorBuffer,
           let voxelPipelineState {
            encoder.setDepthStencilState(paintersDepthStencilState)
            encoder.setRenderPipelineState(voxelPipelineState)
            encoder.setVertexBuffer(cubeVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(geometry, offset: 0, index: 1)
            encoder.setVertexBuffer(colors, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 3)
            // One draw call per Z layer, back-to-front from the current eye position -- not a full
            // per-instance sort (expensive at ~100k+ cells, re-run every orbit frame), but sorting
            // whole layers gets every cell *within* a layer correct for free (they share a Z), and is
            // only wrong across layers when the camera is close to edge-on to the board -- an angle
            // this view isn't really meant to be inspected from anyway. Same painter's-algorithm-fix
            // pattern as the overlay's own copper layers above.
            let sortedZLayers = eye.z >= target.z
                ? voxelZLayerDraws.sorted { $0.z < $1.z } // camera above: farthest (lowest Z) first
                : voxelZLayerDraws.sorted { $0.z > $1.z } // camera below: farthest (highest Z) first
            for layer in sortedZLayers {
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.unitCubeVertices.count,
                                        instanceCount: layer.instanceCount, baseInstance: layer.instanceStart)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Builds this frame's camera-orientation quaternion fresh from azimuth/elevation, rather than
    /// storing/accumulating one across drags (see azimuth's own doc comment for why). Equivalent to
    /// the old raw-trig eye-position formula (cos(el)cos(az), cos(el)sin(az), sin(el)) when acting
    /// on local +Z, but *also* gives a well-defined right/up anywhere -- including exactly at the
    /// poles, where the old cross(forward, worldUp)-based approach degenerated (cross product of
    /// two parallel vectors is zero). Order: first tilt local +Z down from straight-up by
    /// (90-elevation) around Y, then yaw the result around Z by azimuth -- chosen so that acting on
    /// local +Z reproduces the old formula exactly.
    private func currentOrientation() -> simd_quatf {
        simd_quatf(angle: azimuth, axis: SIMD3<Float>(0, 0, 1)) *
            simd_quatf(angle: .pi / 2 - elevation, axis: SIMD3<Float>(0, 1, 0))
    }

    /// The camera's own world-space position -- shared by draw()'s own view-matrix construction and
    /// its overlay-layer back-to-front sort, so both read the same eye position without duplicating
    /// the quaternion->cartesian math.
    private func currentEyePosition() -> SIMD3<Float> {
        SIMD3<Float>(target.x, target.y, target.z) + distance * currentOrientation().act(SIMD3<Float>(0, 0, 1))
    }

    /// The camera's own current right/up basis vectors (screen-space horizontal/vertical, in world
    /// coordinates), read directly off currentOrientation() -- exactly the same up passed to
    /// lookAt() in draw(in:), so panning shifts `target` along axes that actually match what's on
    /// screen. See GeometryView's matching currentOrientation() doc comment for why right/up come
    /// from local +Y and *negated* local +X, not the more intuitive-looking local +X/+Y -- this
    /// construction is identical, so the same fix applies here.
    private func cameraRightAndUp() -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let o = currentOrientation()
        return (o.act(SIMD3<Float>(0, 1, 0)), -o.act(SIMD3<Float>(1, 0, 0)))
    }

    private func currentProjectionMatrix() -> simd_float4x4 {
        let aspect = Float(max(drawableSize.width, 1) / max(drawableSize.height, 1))
        // Near/far tightly bracket the scene's own bounding sphere as seen from the current camera
        // position, not a fixed ratio of `distance` alone -- a fixed near=distance*0.001/
        // far=distance*10 range (this view's original approach) spans four orders of magnitude far
        // more than the actual content ever occupies, which starves a standard (non-reversed)
        // depth buffer of precision exactly where the voxel cells themselves are -- adjacent cells'
        // depths round to the same or adjacent depth-buffer values, producing severe z-fighting.
        //
        // `sceneRadius` is a one-time fit from resetCameraIfNeeded(), not something that tracks the
        // current zoom -- once the user zooms in past `distance < sceneRadius * 1.5` (this view has
        // no minimum-zoom limit), `distance - sceneRadius*1.5` goes negative and `near` collapsed to
        // the old absolute `0.001` floor, while `far` stayed pinned to the stale, now much-too-large
        // `distance + sceneRadius*1.5`. That produced a near:far ratio in the millions -- the classic
        // cause of a standard (non-reversed) depth buffer crushing nearly everything into the last
        // few ULPs near 1.0 (confirmed via Metal's frame debugger: every voxel fragment's depth
        // landed in [0.999, 1.0]), which reads as severe z-fighting even though the geometry itself
        // is fine. `effectiveRadius` caps the radius used for bracketing at the *current* distance,
        // so near/far shrink together as you zoom in rather than near collapsing alone -- the
        // original tight scene-fit bracket is unchanged once zoomed back out past the real radius.
        let effectiveRadius = min(sceneRadius, distance)
        let near = max(distance - effectiveRadius * 1.5, distance * 0.01, 0.001)
        let far = max(distance + effectiveRadius * 1.5, near + 0.001)
        return perspective(fovYRadians: .pi / 4, aspect: aspect, near: near, far: far)
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
        if let snapshot = fieldSnapshot, let minX = snapshot.lineX.first?.floatValue,
           let maxX = snapshot.lineX.last?.floatValue, let minY = snapshot.lineY.first?.floatValue,
           let maxY = snapshot.lineY.last?.floatValue {
            return (minX, maxX, minY, maxY, Float(snapshot.boardZMin), Float(snapshot.boardZMax))
        }
        guard let preview, preview.width > 0, preview.height > 0 else { return nil }
        let minX = Float(preview.xMin)
        let minY = Float(preview.yMin)
        return (minX, minX + Float(preview.width), minY, minY + Float(preview.height), 0, 0)
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
        elevation -= dy * sensitivity
        self.lastDragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
    }

    /// Pan: shifts `target` (the orbit center) along the camera's own current right/up axes --
    /// see rightMouseDragged(_:)'s own doc comment for the perspective-specific world-per-point
    /// approximation this uses (unlike GeometryView's exact orthographic one).
    override func rightMouseDown(with event: NSEvent) {
        lastPanDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let lastPanDragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastPanDragPoint.x)
        let dy = Float(point.y - lastPanDragPoint.y)
        self.lastPanDragPoint = point

        // Perspective camera -- world-units-per-screen-point genuinely depends on depth, unlike
        // GeometryView's orthographic pan (a single ratio, exact everywhere). Approximated here at
        // the orbit target's own depth (== `distance`, by definition of an orbit camera), so the
        // point *at the target* tracks the cursor 1:1; points nearer/farther the camera won't
        // track exactly, which is inherent to perspective, not a bug -- the same reason dragging a
        // perspective viewport never gives a perfectly rigid "grab" feel the way an orthographic
        // one does.
        let worldPerPoint = 2 * distance * tan(Float.pi / 4 / 2) / Float(max(bounds.height, 1))
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
        guard fieldSnapshot != nil || preview != nil else { return }
        let factor = Float(1 - event.scrollingDeltaY * 0.01)
        zoom(by: factor)
    }

    override func magnify(with event: NSEvent) {
        guard fieldSnapshot != nil || preview != nil else { return }
        zoom(by: Float(1 - event.magnification))
    }

    private func zoom(by factor: Float) {
        guard factor > 0 else { return }
        distance = min(max(distance * factor, 0.01), 1_000_000_000)
        needsDisplay = true
    }

    // MARK: - Overlay geometry (simplified reproduction of the Geometry tab's own board render, at
    // board-top Z, uniformly translucent)

    private static let overlayAlpha: Float = 0.5
    private static let overlayOutlineColor = SIMD4<Float>(0.7, 0.7, 0.7, overlayAlpha)
    // Same solder-mask green as GeometryView's own fixed solderMaskColor, just at this view's own
    // translucent overlayAlpha rather than fully opaque.
    private static let overlaySolderMaskColor = SIMD4<Float>(0.0, 0.35, 0.16, overlayAlpha)

    private func rebuildOverlayBuffers() {
        guard let device, let preview else {
            overlayVertexCount = 0
            overlayLayerDraws = []
            overlayMarkerRange = nil
            return
        }
        // Real board thickness, not a single flattened plane -- an earlier version of this function
        // put every copper layer at the same Z (board top), which was fine for GeometryView's own
        // flat, depth-test-free 2D painter's-algorithm rendering, but is fatal here: a multi-layer
        // board's copper regions overlap heavily in XY across layers, so identical-depth triangles
        // have no way to resolve per-pixel winner against a real depth buffer -- exactly the
        // fine-grained triangular z-fighting seen in practice. Each layer is placed at its own real
        // Z (layer.z -- the cumulative real substrate thickness above it, exactly matching where
        // the actual FDTD simulation places it -- see EMSGeometryLayer.z's own doc comment), not an
        // even-spacing approximation across [boardZMin, boardZMax] by index (an earlier version of
        // this function did that, back when EMSGeometryLayer carried no Z of its own).
        let topZ: Float
        let bottomZ: Float
        if let snapshot = fieldSnapshot {
            topZ = Float(snapshot.boardZMax)
            bottomZ = Float(snapshot.boardZMin)
        } else {
            let zValues = preview.layers.map { Float($0.z) }
            topZ = zValues.max() ?? 0
            bottomZ = zValues.min() ?? 0
        }
        // The outline sits visibly above every copper layer, not coincident with the topmost one --
        // same z-fighting concern as the layers above, avoided with a small nudge (1% of board
        // thickness) rather than reusing the topmost layer's own Z exactly.
        let markerZ = topZ + max(topZ - bottomZ, 1) * 0.01
        var positions: [Position3] = []
        var colors: [SIMD4<Float>] = []
        var layerDraws: [(z: Float, start: Int, count: Int)] = []

        for (index, layer) in preview.layers.enumerated() {
            // Silkscreen is an optional diagnostic layer in the Geometry screen and starts there
            // unchecked. The field viewer has no corresponding layer controls, so keep its overlay
            // limited to the physical simulation stack it has always shown.
            guard layer.name != "F.Silkscreen", layer.name != "B.Silkscreen" else { continue }
            let color = Self.overlayLayerColor(layer, index: index, total: preview.layers.count)
            let z = Float(layer.z)
            let start = positions.count
            for triangle in layer.triangles {
                positions.append(contentsOf: [Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                                               Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                                               Position3(Float(triangle.c.x), Float(triangle.c.y), z)])
                colors.append(contentsOf: [color, color, color])
            }
            let count = positions.count - start
            if count > 0 {
                layerDraws.append((z: z, start: start, count: count))
            }
        }

        // Solder mask, if this board's stackup has one on that side (see EMSGeometryPreview.
        // topSolderMask/bottomSolderMask's own doc comment) -- folded into the same layerDraws list
        // as the copper layers just above, so it gets the identical per-frame back-to-front sort
        // (draw(in:)) and the same translucent overlay treatment, just with a fixed color rather
        // than one cycled/looked-up per copper layer.
        for maskLayer in [preview.topSolderMask, preview.bottomSolderMask].compactMap({ $0 }) {
            let z = Float(maskLayer.z)
            let start = positions.count
            for triangle in maskLayer.triangles {
                positions.append(contentsOf: [Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                                               Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                                               Position3(Float(triangle.c.x), Float(triangle.c.y), z)])
                colors.append(contentsOf: [Self.overlaySolderMaskColor, Self.overlaySolderMaskColor,
                                            Self.overlaySolderMaskColor])
            }
            let count = positions.count - start
            if count > 0 {
                layerDraws.append((z: z, start: start, count: count))
            }
        }

        let markerStart = positions.count
        // Real 3D via geometry (open barrel tube + per-layer annular rings -- see
        // EMSGeometryPreview.viaMeshTriangles' own doc comment), each vertex keeping its own real Z
        // -- not the shared flat markerZ a single translucent disc used to sit at. Still part of this
        // same always-drawn-last, no-real-depth-test marker batch as the outline below (see this
        // function's own top comment on why: a real depth-tested via would get inconsistently
        // occluded by whichever dim voxel/layer triangles happen to be nearer the camera, when the
        // whole point of a marker here is staying reliably visible) -- only the *shape* drawn there
        // changed, not which pass draws it.
        for triangle in preview.viaMeshTriangles {
            positions.append(contentsOf: [
                Position3(Float(triangle.a.x), Float(triangle.a.y), Float(triangle.a.z)),
                Position3(Float(triangle.b.x), Float(triangle.b.y), Float(triangle.b.z)),
                Position3(Float(triangle.c.x), Float(triangle.c.y), Float(triangle.c.z)),
            ])
            let color = SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y), Float(triangle.color.z),
                                       Self.overlayAlpha)
            colors.append(contentsOf: [color, color, color])
        }
        // Outline, as a thin flat ribbon (a plain line primitive would need line-width support this
        // pipeline doesn't set up) -- two triangles per edge, a fixed board-space half-thickness
        // small enough to read as a hairline at typical zoom.
        let outlinePoints = preview.outline.map { $0.pointValue }
        if outlinePoints.count > 1 {
            let halfThickness: CGFloat = max(preview.width, preview.height) * 0.001
            for i in 0..<outlinePoints.count {
                let a = outlinePoints[i]
                let b = outlinePoints[(i + 1) % outlinePoints.count]
                Self.appendRibbonSegment(from: a, to: b, halfThickness: halfThickness, z: markerZ,
                                          color: Self.overlayOutlineColor, positions: &positions, colors: &colors)
            }
        }

        let markerCount = positions.count - markerStart
        overlayMarkerRange = markerCount > 0 ? (start: markerStart, count: markerCount) : nil
        overlayLayerDraws = layerDraws

        overlayVertexCount = positions.count
        overlayPositionBuffer = positions.isEmpty ? nil : device.makeBuffer(
            bytes: positions, length: MemoryLayout<Position3>.stride * positions.count)
        overlayColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count)
    }

    private static func appendRibbonSegment(from a: CGPoint, to b: CGPoint, halfThickness: CGFloat, z: Float,
                                             color: SIMD4<Float>, positions: inout [Position3],
                                             colors: inout [SIMD4<Float>]) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return }
        // Perpendicular unit vector, scaled to halfThickness.
        let nx = -dy / length * halfThickness
        let ny = dx / length * halfThickness
        let p0 = Position3(Float(a.x + nx), Float(a.y + ny), z)
        let p1 = Position3(Float(a.x - nx), Float(a.y - ny), z)
        let p2 = Position3(Float(b.x + nx), Float(b.y + ny), z)
        let p3 = Position3(Float(b.x - nx), Float(b.y - ny), z)
        positions.append(contentsOf: [p0, p1, p2, p1, p3, p2])
        colors.append(contentsOf: [color, color, color, color, color, color])
    }

    /// Simplified color resolution (not GeometryView's full KiCad-default-table lookup -- this is a
    /// translucent spatial reference, not the primary board view, so an approximate per-layer color
    /// is enough): the layer's own hex color if present, else an evenly-spaced hue.
    private static func overlayLayerColor(_ layer: EMSGeometryLayer, index: Int, total: Int) -> SIMD4<Float> {
        if let hex = layer.hexColor, let rgb = parseHexColor(hex) {
            return SIMD4(rgb.0, rgb.1, rgb.2, overlayAlpha)
        }
        guard total > 1 else { return SIMD4(0.9, 0.5, 0.1, overlayAlpha) }
        let color = NSColor(calibratedHue: CGFloat(index) / CGFloat(total), saturation: 0.65, brightness: 0.85,
                             alpha: 1).usingColorSpace(.deviceRGB)
        return SIMD4(Float(color?.redComponent ?? 0.5), Float(color?.greenComponent ?? 0.5),
                      Float(color?.blueComponent ?? 0.5), overlayAlpha)
    }

    /// Parses "#RRGGBB"/"#RRGGBBAA" (see EMSGeometryLayer.hexColor's own doc comment).
    private static func parseHexColor(_ hex: String) -> (Float, Float, Float)? {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let shift = digits.count == 8 ? 24 : 16
        let r = Float((value >> shift) & 0xFF) / 255
        let g = Float((value >> (shift - 8)) & 0xFF) / 255
        let b = Float((value >> (shift - 16)) & 0xFF) / 255
        return (r, g, b)
    }

    // MARK: - Voxel geometry (one instanced cube per FDTD cell)

    // Unit cube, corners at +/-0.5 on each axis, 12 triangles/36 vertices, CCW winding as seen from
    // outside each face -- no backface culling is configured (see makePipelineState's own doc
    // comment on why unsorted alpha blending is already an approximation; culling would just hide
    // interior-facing surfaces that a translucent cube arguably ought to still contribute to the
    // blend).
    private static let unitCubeVertices: [Position3] = {
        let p: [Position3] = [
            Position3(-0.5, -0.5, -0.5), Position3(0.5, -0.5, -0.5), Position3(0.5, 0.5, -0.5),
            Position3(-0.5, 0.5, -0.5), Position3(-0.5, -0.5, 0.5), Position3(0.5, -0.5, 0.5),
            Position3(0.5, 0.5, 0.5), Position3(-0.5, 0.5, 0.5),
        ]
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> [Position3] {
            [p[a], p[b], p[c], p[a], p[c], p[d]]
        }
        return quad(0, 1, 2, 3) // -Z
            + quad(5, 4, 7, 6) // +Z
            + quad(4, 0, 3, 7) // -X
            + quad(1, 5, 6, 2) // +X
            + quad(4, 5, 1, 0) // -Y
            + quad(3, 2, 6, 7) // +Y
    }()

    private static let gradientAlphaAtZero: Float = 0.01
    private static let gradientAlphaAtOne: Float = 0.75

    private static func gradientColor(t: Float) -> SIMD4<Float> {
        let clamped = min(max(t, 0), 1)
        let rgb = EnergyColorMap.rgb(at: CGFloat(clamped))
        let alpha = gradientAlphaAtZero + (gradientAlphaAtOne - gradientAlphaAtZero) * clamped
        return SIMD4(Float(rgb.red), Float(rgb.green), Float(rgb.blue), alpha)
    }

    /// Converts `n` Yee-grid sample *points* (one per E-field line along an axis -- see
    /// rebuildVoxelGeometry()'s own doc comment on why snapshot.lineX/Y/Z are points, not cell
    /// boundaries) into `n+1` cell boundaries: each point sits at the center of its own cell, whose
    /// edges are the midpoint to each neighboring point. The two outermost cells have only one
    /// neighbor, so they're extended by that same single gap (symmetric around the outermost point)
    /// rather than left half-width -- this is the standard "point-centered" reconstruction, and it's
    /// exact for the far more common case of a uniform (or slowly-varying) mesh spacing.
    private static func cellBoundaries(from points: [Float]) -> [Float] {
        guard points.count > 1 else { return points.isEmpty ? [] : [points[0], points[0]] }
        var boundaries = [Float](repeating: 0, count: points.count + 1)
        for i in 1..<points.count {
            boundaries[i] = (points[i - 1] + points[i]) / 2
        }
        boundaries[0] = 2 * points[0] - boundaries[1]
        boundaries[points.count] = 2 * points[points.count - 1] - boundaries[points.count - 1]
        return boundaries
    }

    /// Rebuilds the voxel cloud's fixed shape/position data -- called whenever `fieldSnapshot`
    /// changes (a new mesh), never on a plain playback frame change (see updateVoxelColors(forFrame:)
    /// for that, much cheaper, path). Also (re)computes voxelCachedNx/Ny/ZRange, the exact iteration
    /// bounds updateVoxelColors(forFrame:) must reuse to stay in lockstep with this buffer's own
    /// instance order, then populates the color buffer for the current frame.
    private func rebuildVoxelGeometry() {
        hasLoggedVoxelDraw = false
        guard let device, let snapshot = fieldSnapshot else {
            Cu.logDebug("[FieldView] rebuildVoxelGeometry: bailing, device=\(device != nil) snapshot=\(fieldSnapshot != nil)")
            voxelInstanceCount = 0
            voxelCachedZRange = nil
            voxelCachedEnergyIndices = []
            voxelZLayerDraws = []
            return
        }
        // snapshot.lineX/Y/Z are Yee-grid *sample points* (one per E-field line, matching
        // copper::CopperYeeGrid's own dims.nx == op.GetNumberOfLines(0) -- see CopperYeeGrid.cpp),
        // not the nx+1 cell boundaries this function used to assume: each has exactly nx/ny/nz
        // entries, the same count as snapshot.nx/ny/nz and cellEnergyData's own per-axis stride.
        // cellBoundaries(from:) below reconstructs the nx+1/ny+1/nz+1 boundary array each voxel's
        // extent actually needs, from those sample points -- this was the reason the voxel cloud
        // wasn't rendering at all (the old nx+1 guard failed every time, silently).
        let sampleX = snapshot.lineX.map(\.floatValue)
        let sampleY = snapshot.lineY.map(\.floatValue)
        let sampleZ = snapshot.lineZ.map(\.floatValue)
        let nx = Int(snapshot.nx)
        let ny = Int(snapshot.ny)
        let nz = Int(snapshot.nz)
        // TEMPORARY diagnostic: confirms the mesh dims/line counts actually landing here, and
        // whether the frame count/board-Z values look sane -- see this file's own top comment on why
        // the voxel cloud is reportedly not rendering at all right now.
        Cu.logDebug("[FieldView] rebuildVoxelGeometry: nx=\(nx) ny=\(ny) nz=\(nz) sampleX.count=\(sampleX.count) "
            + "sampleY.count=\(sampleY.count) sampleZ.count=\(sampleZ.count) frames=\(snapshot.frames.count) "
            + "boardZMin=\(snapshot.boardZMin) boardZMax=\(snapshot.boardZMax) "
            + "minEnergy=\(snapshot.minCellEnergy) maxEnergy=\(snapshot.maxCellEnergy)")
        guard nx > 0, ny > 0, nz > 0, sampleX.count == nx, sampleY.count == ny, sampleZ.count == nz else {
            Cu.logWarning("[FieldView] rebuildVoxelGeometry: bailing on dims/sample-count mismatch")
            voxelInstanceCount = 0
            voxelCachedZRange = nil
            voxelCachedEnergyIndices = []
            voxelZLayerDraws = []
            return
        }
        if rebuildRefinedVoxelGeometry(forFrame: currentFrameIndex) { return }
        let lineX = Self.cellBoundaries(from: sampleX)
        let lineY = Self.cellBoundaries(from: sampleY)
        let lineZ = Self.cellBoundaries(from: sampleZ)

        // Z is cropped to the board's own top/bottom (not the full PML/margin-extended mesh -- see
        // this class's own top comment and EMSFieldSnapshot.boardZMin/boardZMax's doc comment): X/Y
        // stay at the mesh's own full extent, since spurious energy near/in the PML boundary is
        // exactly what this view exists to help spot spatially. `zStart`/`zEnd` are cell *index*
        // bounds (inclusive) into lineZ/cellEnergy's own Z axis.
        let boardZMin = Float(snapshot.boardZMin)
        let boardZMax = Float(snapshot.boardZMax)
        var zStart = 0
        var zEnd = nz - 1
        while zStart < nz, lineZ[zStart + 1] < boardZMin { zStart += 1 }
        // lineZ[zEnd + 1], not lineZ[zEnd] -- cell `zEnd` occupies [lineZ[zEnd], lineZ[zEnd+1]], so
        // its *upper* boundary (the one that matters for "is this cell entirely above the board")
        // is at index zEnd+1. The original off-by-one tested the cell's lower boundary instead,
        // which could leave one extra PML/margin cell included just above the board.
        while zEnd > zStart, lineZ[zEnd + 1] > boardZMax { zEnd -= 1 }
        Cu.logDebug("[FieldView] rebuildVoxelGeometry: boardZMin=\(boardZMin) boardZMax=\(boardZMax) zStart=\(zStart) "
            + "zEnd=\(zEnd) lineZ.first=\(lineZ.first ?? .nan) lineZ.last=\(lineZ.last ?? .nan)")
        guard zStart <= zEnd else {
            Cu.logWarning("[FieldView] rebuildVoxelGeometry: bailing, zStart > zEnd (board Z crop produced an empty range)")
            voxelInstanceCount = 0
            voxelCachedZRange = nil
            voxelCachedEnergyIndices = []
            voxelZLayerDraws = []
            return
        }

        // "Poke out" the two outermost included Z boundaries by 1/4 of the smallest included cell's
        // own Z thickness, so the voxel space's top/bottom layers extend slightly past the board's
        // real top/bottom surface rather than stopping exactly at it.
        var smallestZThickness = Float.greatestFiniteMagnitude
        for z in zStart...zEnd {
            smallestZThickness = min(smallestZThickness, lineZ[z + 1] - lineZ[z])
        }
        let stretch = smallestZThickness.isFinite ? smallestZThickness / 4 : 0
        var stretchedLineZ = Array(lineZ[zStart...(zEnd + 1)])
        stretchedLineZ[0] -= stretch
        stretchedLineZ[stretchedLineZ.count - 1] += stretch

        var geometryInstances: [VoxelGeometryGPU] = []
        let estimatedInstanceCount = nx * ny * (zEnd - zStart + 1)
        geometryInstances.reserveCapacity(estimatedInstanceCount)
        var energyIndices: [Int] = []
        energyIndices.reserveCapacity(estimatedInstanceCount)
        let fullNx = Int(snapshot.fullNx), fullNy = Int(snapshot.fullNy)
        let factorX = Int(snapshot.previewFactorX), factorY = Int(snapshot.previewFactorY)
        let fullX = Self.cellBoundaries(from: snapshot.fullLineX.map(\.floatValue))
        let fullY = Self.cellBoundaries(from: snapshot.fullLineY.map(\.floatValue))
        let domain = snapshot.fullDomainXYClassData.withUnsafeBytes { Array($0) }
        let hasDomain = domain.count == fullNx * fullNy && fullX.count == fullNx + 1 && fullY.count == fullNy + 1
        func active(_ x: Int, _ y: Int) -> Bool {
            !hasDomain || domain[x + fullNx * y] != 0
        }
        var zLayerDraws: [(z: Float, instanceStart: Int, instanceCount: Int)] = []
        for iz in zStart...zEnd {
            let z0 = stretchedLineZ[iz - zStart]
            let z1 = stretchedLineZ[iz - zStart + 1]
            let zCenter = (z0 + z1) / 2
            let zSize = z1 - z0
            let layerStart = geometryInstances.count
            for iy in 0..<ny {
                let y0 = lineY[iy]
                let y1 = lineY[iy + 1]
                let yCenter = (y0 + y1) / 2
                let ySize = y1 - y0
                for ix in 0..<nx {
                    let energyIndex = ix + nx * (iy + ny * iz)
                    let startX = ix * factorX, endX = min(startX + factorX, fullNx)
                    let startY = iy * factorY, endY = min(startY + factorY, fullNy)
                    var activeCount = 0
                    for gy in startY..<endY {
                        for gx in startX..<endX where active(gx, gy) { activeCount += 1 }
                    }
                    if activeCount == 0 { continue }
                    let blockCount = (endX - startX) * (endY - startY)
                    if activeCount != blockCount {
                        for gy in startY..<endY {
                            for gx in startX..<endX where active(gx, gy) {
                                geometryInstances.append(VoxelGeometryGPU(
                                    center: Position3((fullX[gx] + fullX[gx + 1]) / 2,
                                                      (fullY[gy] + fullY[gy + 1]) / 2, zCenter),
                                    size: Position3(fullX[gx + 1] - fullX[gx],
                                                    fullY[gy + 1] - fullY[gy], zSize)))
                                energyIndices.append(energyIndex)
                            }
                        }
                        continue
                    }
                    let x0 = lineX[ix]
                    let x1 = lineX[ix + 1]
                    geometryInstances.append(VoxelGeometryGPU(center: Position3((x0 + x1) / 2, yCenter, zCenter),
                                                                size: Position3(x1 - x0, ySize, zSize)))
                    energyIndices.append(energyIndex)
                }
            }
            zLayerDraws.append((z: zCenter, instanceStart: layerStart, instanceCount: geometryInstances.count - layerStart))
        }

        voxelInstanceCount = geometryInstances.count
        voxelGeometryBuffer = geometryInstances.isEmpty ? nil : device.makeBuffer(
            bytes: geometryInstances, length: MemoryLayout<VoxelGeometryGPU>.stride * geometryInstances.count)
        voxelZLayerDraws = zLayerDraws
        voxelCachedNx = nx
        voxelCachedNy = ny
        voxelCachedZRange = zStart...zEnd
        voxelCachedEnergyIndices = energyIndices
        voxelCachedMaxEnergy = 0
        Cu.logDebug("[FieldView] rebuildVoxelGeometry: built \(voxelInstanceCount) instances, "
            + "voxelGeometryBuffer=\(voxelGeometryBuffer != nil)")

        updateVoxelColors(forFrame: currentFrameIndex)
    }

    /// Replaces preview cells prepared by the lookahead decoder with their full-resolution
    /// 16x16x2 (edge-aware) children. Geometry and energy stay in matching per-Z buckets so the
    /// existing painter-order draw path remains valid even when coarse and fine cells coexist.
    @discardableResult
    private func rebuildRefinedVoxelGeometry(forFrame frameIndex: Int) -> Bool {
        guard let device, let snapshot = fieldSnapshot,
              snapshot.frames.indices.contains(frameIndex) else { return false }
        let decoded = snapshot.frames[frameIndex].decodedFrame
        guard !decoded.refinements.isEmpty else { return false }

        let nx = Int(snapshot.nx), ny = Int(snapshot.ny), nz = Int(snapshot.nz)
        let factorX = Int(snapshot.previewFactorX)
        let factorY = Int(snapshot.previewFactorY)
        let factorZ = Int(snapshot.previewFactorZ)
        let fullX = Self.cellBoundaries(from: snapshot.fullLineX.map(\.floatValue))
        let fullY = Self.cellBoundaries(from: snapshot.fullLineY.map(\.floatValue))
        let fullZ = Self.cellBoundaries(from: snapshot.fullLineZ.map(\.floatValue))
        guard fullX.count == Int(snapshot.fullNx) + 1,
              fullY.count == Int(snapshot.fullNy) + 1,
              fullZ.count == Int(snapshot.fullNz) + 1 else { return false }

        let previewEnergy = decoded.previewEnergyData.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }
        guard previewEnergy.count == nx * ny * nz else { return false }
        let refinements = Dictionary(uniqueKeysWithValues: decoded.refinements.map {
            (Int($0.previewCellIndex), $0)
        })
        let domain = snapshot.fullDomainXYClassData.withUnsafeBytes { Array($0) }
        let hasDomain = domain.count == Int(snapshot.fullNx) * Int(snapshot.fullNy)
        func active(_ x: Int, _ y: Int) -> Bool {
            !hasDomain || domain[x + Int(snapshot.fullNx) * y] != 0
        }
        let boardMin = Float(snapshot.boardZMin)
        let boardMax = Float(snapshot.boardZMax)
        var buckets: [Float: [(VoxelGeometryGPU, Float)]] = [:]

        for iz in 0..<nz {
            let coarseStartZ = iz * factorZ
            let coarseEndZ = min(coarseStartZ + factorZ, Int(snapshot.fullNz))
            guard fullZ[coarseEndZ] >= boardMin, fullZ[coarseStartZ] <= boardMax else { continue }
            for iy in 0..<ny {
                for ix in 0..<nx {
                    let previewIndex = ix + nx * (iy + ny * iz)
                    guard let refinement = refinements[previewIndex] else {
                        // Derive coarse extents from the exact full-grid block edges, not from
                        // midpoints between reduced preview centres. This makes refined and coarse
                        // neighbours meet exactly on nonuniform meshes.
                        let startX = ix * factorX, startY = iy * factorY
                        let endX = min(startX + factorX, Int(snapshot.fullNx))
                        let endY = min(startY + factorY, Int(snapshot.fullNy))
                        let z0 = fullZ[coarseStartZ], z1 = fullZ[coarseEndZ]
                        let centerZ = (z0 + z1) / 2
                        var activeCount = 0
                        for gy in startY..<endY {
                            for gx in startX..<endX where active(gx, gy) { activeCount += 1 }
                        }
                        if activeCount == 0 { continue }
                        if activeCount != (endX - startX) * (endY - startY) {
                            for gy in startY..<endY {
                                for gx in startX..<endX where active(gx, gy) {
                                    let geometry = VoxelGeometryGPU(
                                        center: Position3((fullX[gx] + fullX[gx + 1]) / 2,
                                                          (fullY[gy] + fullY[gy + 1]) / 2, centerZ),
                                        size: Position3(fullX[gx + 1] - fullX[gx],
                                                        fullY[gy + 1] - fullY[gy], z1 - z0))
                                    buckets[centerZ, default: []].append((geometry, previewEnergy[previewIndex]))
                                }
                            }
                            continue
                        }
                        let geometry = VoxelGeometryGPU(
                            center: Position3((fullX[startX] + fullX[endX]) / 2,
                                              (fullY[startY] + fullY[endY]) / 2, centerZ),
                            size: Position3(fullX[endX] - fullX[startX],
                                            fullY[endY] - fullY[startY], z1 - z0))
                        buckets[centerZ, default: []].append((geometry, previewEnergy[previewIndex]))
                        continue
                    }
                    let detailEnergy = refinement.cellEnergyData.withUnsafeBytes {
                        Array($0.bindMemory(to: Float.self))
                    }
                    let detailNx = Int(refinement.nx), detailNy = Int(refinement.ny), detailNz = Int(refinement.nz)
                    guard detailEnergy.count == detailNx * detailNy * detailNz else { continue }
                    let startX = ix * factorX, startY = iy * factorY, startZ = iz * factorZ
                    for dz in 0..<detailNz {
                        let gz = startZ + dz
                        let z0 = fullZ[gz], z1 = fullZ[gz + 1]
                        guard z1 >= boardMin, z0 <= boardMax else { continue }
                        let centerZ = (z0 + z1) / 2
                        for dy in 0..<detailNy {
                            let gy = startY + dy
                            for dx in 0..<detailNx {
                                let gx = startX + dx
                                guard active(gx, gy) else { continue }
                                let geometry = VoxelGeometryGPU(
                                    center: Position3((fullX[gx] + fullX[gx + 1]) / 2,
                                                      (fullY[gy] + fullY[gy + 1]) / 2, centerZ),
                                    size: Position3(fullX[gx + 1] - fullX[gx],
                                                    fullY[gy + 1] - fullY[gy], z1 - z0))
                                let value = detailEnergy[dx + detailNx * (dy + detailNy * dz)]
                                buckets[centerZ, default: []].append((geometry, value))
                            }
                        }
                    }
                }
            }
        }

        let orderedZ = buckets.keys.sorted()
        let allEnergy = orderedZ.flatMap { buckets[$0, default: []].map(\.1) }
        if let frameMax = allEnergy.max() { seriesOnBoardMaxEnergy = max(seriesOnBoardMaxEnergy, frameMax) }
        let maxEnergy = seriesOnBoardMaxEnergy
        let floorEnergy = maxEnergy > 0 ? maxEnergy * 1e-6 : 0
        let logMax = log10(max(maxEnergy, Float.leastNormalMagnitude))
        let logFloor = log10(max(floorEnergy, Float.leastNormalMagnitude))
        let logSpan = max(logMax - logFloor, Float.leastNormalMagnitude)
        var geometry: [VoxelGeometryGPU] = []
        var colors: [Color4] = []
        var draws: [(z: Float, instanceStart: Int, instanceCount: Int)] = []
        geometry.reserveCapacity(allEnergy.count)
        colors.reserveCapacity(allEnergy.count)
        for z in orderedZ {
            let start = geometry.count
            for (instance, energy) in buckets[z, default: []] {
                geometry.append(instance)
                let t = min(max((log10(max(energy, Float.leastNormalMagnitude)) - logFloor) / logSpan, 0), 1)
                let color = Self.gradientColor(t: t)
                colors.append(Color4(color.x, color.y, color.z, color.w))
            }
            draws.append((z: z, instanceStart: start, instanceCount: geometry.count - start))
        }
        voxelInstanceCount = geometry.count
        voxelGeometryBuffer = geometry.isEmpty ? nil : device.makeBuffer(
            bytes: geometry, length: MemoryLayout<VoxelGeometryGPU>.stride * geometry.count)
        voxelColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<Color4>.stride * colors.count)
        voxelZLayerDraws = draws
        voxelCachedMaxEnergy = maxEnergy
        voxelCachedEnergyIndices = []
        return true
    }

    /// Recomputes just the per-instance color buffer for one playback frame, reusing the cell-grid
    /// bounds rebuildVoxelGeometry() last cached -- must walk (iz, iy, ix) in that exact same nested
    /// order so instance N here lines up with instance N in voxelGeometryBuffer. This is the entire
    /// per-frame cost of scrubbing/playing back the timeline: no Metal buffer beyond the color one
    /// is touched, and no positions/sizes are recomputed.
    private func updateVoxelColors(forFrame frameIndex: Int) {
        guard let device, let snapshot = fieldSnapshot, let zRange = voxelCachedZRange,
              frameIndex >= 0, frameIndex < snapshot.frames.count else {
            Cu.logDebug("[FieldView] updateVoxelColors: bailing, device=\(device != nil) snapshot=\(fieldSnapshot != nil) "
                + "zRange=\(String(describing: voxelCachedZRange)) frameIndex=\(frameIndex) "
                + "frameCount=\(fieldSnapshot?.frames.count ?? -1)")
            voxelColorBuffer = nil
            return
        }
        let nx = voxelCachedNx
        let ny = voxelCachedNy
        let energyStride = nx * ny
        let nz = Int(snapshot.nz)
        let frame = snapshot.frames[frameIndex]
        let cellEnergy = frame.cellEnergyData.withUnsafeBytes { buffer -> [Float] in
            Array(buffer.bindMemory(to: Float.self))
        }
        guard cellEnergy.count == nx * ny * nz else {
            Cu.logWarning("[FieldView] updateVoxelColors: bailing, cellEnergy.count=\(cellEnergy.count) "
                + "expected=\(nx * ny * nz) (nx=\(nx) ny=\(ny) nz=\(nz))")
            voxelColorBuffer = nil
            return
        }

        // Fold only this just-streamed frame into the stable on-board scale. Excluding the
        // PML/margin cells keeps boundary-adjacent values from swamping the board visualization,
        // while avoiding the old eager pass over every frame when the viewer opened.
        let onBoardStart = zRange.lowerBound * energyStride
        let onBoardEnd = (zRange.upperBound + 1) * energyStride
        let displayedEnergy = voxelCachedEnergyIndices.compactMap { index in
            index >= onBoardStart && index < onBoardEnd ? cellEnergy[index] : nil
        }
        if let frameMax = displayedEnergy.max() {
            seriesOnBoardMaxEnergy = max(seriesOnBoardMaxEnergy, frameMax)
        }
        let maxEnergy = seriesOnBoardMaxEnergy
        voxelCachedMaxEnergy = maxEnergy
        // 60dB below peak -- the same end-criteria dynamic-range convention already used
        // throughout this run's own progress reporting (see CopperFDTDRunner.cpp's own
        // `endCriteria = 1e-6`), reused here so "the bottom of the gradient" means something the
        // rest of this app's own numbers already established, not an arbitrarily chosen floor.
        // Energy is famously log-distributed spatially, so the gradient is mapped over log10(energy)
        // -- a plain linear min...max mapping would render nearly every cell as the very bottom of
        // the gradient except the single brightest spot, defeating the point of a spatial map.
        let floorEnergy = maxEnergy > 0 ? maxEnergy * 1e-6 : 0
        let logMax = log10(max(maxEnergy, Float.leastNormalMagnitude))
        let logFloor = log10(max(floorEnergy, Float.leastNormalMagnitude))
        let logSpan = max(logMax - logFloor, Float.leastNormalMagnitude)

        var colors: [Color4] = []
        colors.reserveCapacity(voxelCachedEnergyIndices.count)
        for index in voxelCachedEnergyIndices {
            let energy = cellEnergy[index]
            let logEnergy = log10(max(energy, Float.leastNormalMagnitude))
            let t = min(max((logEnergy - logFloor) / logSpan, 0), 1)
            let color = Self.gradientColor(t: t)
            colors.append(Color4(color.x, color.y, color.z, color.w))
        }

        voxelColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<Color4>.stride * colors.count)
        Cu.logDebug("[FieldView] updateVoxelColors: frame=\(frameIndex) built \(colors.count) colors, "
            + "voxelColorBuffer=\(voxelColorBuffer != nil), floorEnergy=\(floorEnergy) maxEnergy=\(maxEnergy)")
    }

    // 60% dark grey-blue -- distinct from GeometryView's own fixed dark canvas, so it's visually
    // obvious which tab is showing without reading the sidebar.
    private static let backgroundColor = MTLClearColor(red: 0.1, green: 0.11, blue: 0.14, alpha: 1)
}

// MARK: - GPU-layout-matching value types
//
// Position3/FieldUniformsGPU (shared with GeometryView's own 3D camera) live in Board3DMath.swift.

/// Same reasoning as Position3 -- a plain 4-`Float` struct so a tightly-packed array of these
/// matches Metal's `packed_float4` exactly, with no `SIMD4<Float>`-style alignment padding between
/// elements.
private struct Color4 {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
    init(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// Matches FieldShaders.metal's own `VoxelGeometry` struct byte-for-byte (see Position3/Color4's
/// own doc comments for why plain-Float structs, not SIMD types, are used throughout).
private struct VoxelGeometryGPU {
    var center: Position3
    var size: Position3
}
