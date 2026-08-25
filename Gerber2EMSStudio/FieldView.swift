import Cocoa
import MetalKit
import simd

/// Renders an EMSFieldSnapshot (the field/energy state Copper captured at the end of a completed
/// GPU FDTD run) as a 3D voxel cloud, plus the same board geometry the Geometry tab shows -- laid
/// out flat at the board's own top Z, at 50% opacity -- as a spatial reference underneath it. Real
/// perspective camera with mouse-drag orbit (unlike GeometryView's flat pan/zoom-only 2D view --
/// see FieldShaders.metal's own top comment for why this needs its own shader pair).
final class FieldView: MTKView, MTKViewDelegate {
    var preview: EMSGeometryPreview? {
        didSet {
            rebuildOverlayBuffers()
            hasFitCamera = false
            needsDisplay = true
        }
    }

    var fieldSnapshot: EMSFieldSnapshot? {
        didSet {
            let frameCount = fieldSnapshot?.frames.count ?? 0
            currentFrameIndex = frameCount > 0 ? min(currentFrameIndex, frameCount - 1) : 0
            rebuildVoxelGeometry()
            hasFitCamera = false
            needsDisplay = true
        }
    }

    /// Which of `fieldSnapshot.frames` the voxel cloud currently displays -- see
    /// rebuildVoxelGeometry()/updateVoxelColors(forFrame:)'s own doc comments for why changing this
    /// only rebuilds the (cheap) per-frame color buffer, not the full cell geometry. Clamped to the
    /// current snapshot's own frame count; left at whatever it was across a snapshot change unless
    /// that would now be out of range (see fieldSnapshot's own didSet).
    var currentFrameIndex: Int = 0 {
        didSet {
            guard currentFrameIndex != oldValue else { return }
            updateVoxelColors(forFrame: currentFrameIndex)
            needsDisplay = true
        }
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
    /// Vias/ports/outline -- appended after every layer's own range, always drawn last/on top (a
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
    /// The peak cell energy across every captured frame, but only within voxelCachedZRange (the
    /// board-thickness Z crop) -- see updateVoxelColors(forFrame:)'s own doc comment for why this,
    /// not EMSFieldSnapshot.maxCellEnergy (the whole mesh's own peak, including the PML/margin
    /// region well outside the board), is what the color gradient is scaled against.
    private var voxelCachedMaxEnergy: Float = 0
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

    // Spherical coordinates around `target`, Z treated as "up" (the board lies flat in the XY
    // plane, Z is its own thin thickness axis -- see EMSFieldSnapshot's own doc comment on the
    // frame) -- azimuth rotates around the vertical Z axis, elevation tilts above/below the
    // horizontal plane, matching a familiar "tilt a physical board in your hand" interaction.
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
    private static let minElevation: Float = -.pi / 2 * 0.98
    private static let maxElevation: Float = .pi / 2 * 0.98

    private var lastDragPoint: CGPoint?

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
            // reference plane whose source triangulation, Clipper2's own tessellation of copper
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
            eye: eye, center: SIMD3(target.x, target.y, target.z), up: SIMD3(0, 0, 1)))

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

    /// The camera's own world-space position -- shared by draw()'s own view-matrix construction and
    /// its overlay-layer back-to-front sort, so both read the same eye position without duplicating
    /// the spherical->cartesian math.
    private func currentEyePosition() -> SIMD3<Float> {
        SIMD3<Float>(target.x + distance * cos(elevation) * cos(azimuth),
                     target.y + distance * cos(elevation) * sin(azimuth),
                     target.z + distance * sin(elevation))
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

    /// Orbit: drag left/right to rotate azimuth, up/down to tilt elevation (clamped shy of the
    /// poles to avoid a gimbal flip -- see minElevation/maxElevation).
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

    /// Trackpad two-finger scroll and a plain scroll wheel zoom (distance), rather than pan --
    /// there's no "pan the target" interaction here (see this class's own top comment: the fixed
    /// orbit target is always the board/voxel cloud's own center).
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
    private static let overlayViaColor = SIMD4<Float>(0xEB / 255, 0xB5 / 255, 0, overlayAlpha)
    private static let overlayPortColor = SIMD4<Float>(0.2, 0.48, 0.98, overlayAlpha)
    private static let overlayCircleSegments = 16

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
        // Vias/ports sit visibly above every copper layer, not coincident with the topmost one --
        // same z-fighting concern as the layers above, avoided with a small nudge (1% of board
        // thickness) rather than reusing the topmost layer's own Z exactly.
        let markerZ = topZ + max(topZ - bottomZ, 1) * 0.01
        var positions: [Position3] = []
        var colors: [SIMD4<Float>] = []
        var layerDraws: [(z: Float, start: Int, count: Int)] = []

        for (index, layer) in preview.layers.enumerated() {
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

        let markerStart = positions.count
        for via in preview.vias {
            let radius = Float(via.annularRingDiameter) / 2
            guard radius > 0 else { continue }
            Self.appendDisc(center: via.ringPosition, radius: CGFloat(radius), z: markerZ, color: Self.overlayViaColor,
                             positions: &positions, colors: &colors)
        }
        for port in preview.ports {
            let radius = max(Float(port.width) / 2, 1)
            Self.appendDisc(center: port.position, radius: CGFloat(radius), z: markerZ, color: Self.overlayPortColor,
                             positions: &positions, colors: &colors)
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

    private static func appendDisc(center: CGPoint, radius: CGFloat, z: Float, color: SIMD4<Float>,
                                    positions: inout [Position3], colors: inout [SIMD4<Float>]) {
        let cx = Float(center.x)
        let cy = Float(center.y)
        let r = Float(radius)
        let centerVertex = Position3(cx, cy, z)
        var previous = Position3(cx + r, cy, z)
        for segment in 1...overlayCircleSegments {
            let angle = Float(segment) / Float(overlayCircleSegments) * 2 * Float.pi
            let current = Position3(cx + r * cos(angle), cy + r * sin(angle), z)
            positions.append(contentsOf: [centerVertex, previous, current])
            colors.append(contentsOf: [color, color, color])
            previous = current
        }
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

    // The energy-density color gradient, 5 stops -- exact colors/opacities as specified; the three
    // middle stops' opacity isn't independently specified, so it's linearly interpolated between
    // the two endpoints (25% at t=0, 75% at t=1) at each stop's own t, matching the same
    // interpolation the renderer already does between stops for color.
    private static let gradientStops: [(t: Float, color: (Float, Float, Float))] = [
        (0.0, (0x2a / 255, 0x2e / 255, 0xac / 255)),
        (0.5, (0xb8 / 255, 0x1f / 255, 0x3c / 255)),
        (0.75, (0xf0 / 255, 0x7f / 255, 0x29 / 255)),
        (0.875, (0xfa / 255, 0xa9 / 255, 0x14 / 255)),
        (1.0, (0xf2 / 255, 0xce / 255, 0x30 / 255)),
    ]
    private static let gradientAlphaAtZero: Float = 0.01
    private static let gradientAlphaAtOne: Float = 0.75

    private static func gradientColor(t: Float) -> SIMD4<Float> {
        let clamped = min(max(t, 0), 1)
        var lower = gradientStops[0]
        var upper = gradientStops[gradientStops.count - 1]
        for i in 0..<(gradientStops.count - 1) {
            if clamped >= gradientStops[i].t, clamped <= gradientStops[i + 1].t {
                lower = gradientStops[i]
                upper = gradientStops[i + 1]
                break
            }
        }
        let span = upper.t - lower.t
        let localT = span > 0 ? (clamped - lower.t) / span : 0
        let r = lower.color.0 + (upper.color.0 - lower.color.0) * localT
        let g = lower.color.1 + (upper.color.1 - lower.color.1) * localT
        let b = lower.color.2 + (upper.color.2 - lower.color.2) * localT
        let alpha = gradientAlphaAtZero + (gradientAlphaAtOne - gradientAlphaAtZero) * clamped
        return SIMD4(r, g, b, alpha)
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
            print("[FieldView] rebuildVoxelGeometry: bailing, device=\(device != nil) snapshot=\(fieldSnapshot != nil)")
            voxelInstanceCount = 0
            voxelCachedZRange = nil
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
        print("[FieldView] rebuildVoxelGeometry: nx=\(nx) ny=\(ny) nz=\(nz) sampleX.count=\(sampleX.count) "
            + "sampleY.count=\(sampleY.count) sampleZ.count=\(sampleZ.count) frames=\(snapshot.frames.count) "
            + "boardZMin=\(snapshot.boardZMin) boardZMax=\(snapshot.boardZMax) "
            + "minEnergy=\(snapshot.minCellEnergy) maxEnergy=\(snapshot.maxCellEnergy)")
        guard nx > 0, ny > 0, nz > 0, sampleX.count == nx, sampleY.count == ny, sampleZ.count == nz else {
            print("[FieldView] rebuildVoxelGeometry: bailing on dims/sample-count mismatch")
            voxelInstanceCount = 0
            voxelCachedZRange = nil
            voxelZLayerDraws = []
            return
        }
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
        print("[FieldView] rebuildVoxelGeometry: boardZMin=\(boardZMin) boardZMax=\(boardZMax) zStart=\(zStart) "
            + "zEnd=\(zEnd) lineZ.first=\(lineZ.first ?? .nan) lineZ.last=\(lineZ.last ?? .nan)")
        guard zStart <= zEnd else {
            print("[FieldView] rebuildVoxelGeometry: bailing, zStart > zEnd (board Z crop produced an empty range)")
            voxelInstanceCount = 0
            voxelCachedZRange = nil
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
        geometryInstances.reserveCapacity(nx * ny * (zEnd - zStart + 1))
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
                    let x0 = lineX[ix]
                    let x1 = lineX[ix + 1]
                    geometryInstances.append(VoxelGeometryGPU(center: Position3((x0 + x1) / 2, yCenter, zCenter),
                                                                size: Position3(x1 - x0, ySize, zSize)))
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
        voxelCachedMaxEnergy = Self.maxEnergy(in: snapshot.frames, nx: nx, ny: ny, zRange: zStart...zEnd)
        print("[FieldView] rebuildVoxelGeometry: built \(voxelInstanceCount) instances, "
            + "voxelGeometryBuffer=\(voxelGeometryBuffer != nil) onBoardMaxEnergy=\(voxelCachedMaxEnergy) "
            + "(whole-mesh maxEnergy was \(snapshot.maxCellEnergy))")
        // TEMPORARY diagnostic: reports the actual on-board energy distribution for the *last*
        // captured frame -- see this file's own top comment on why the voxel cloud reportedly never
        // shows energy anywhere but the excited port, which would contradict this run's own
        // estimateEnergy() dynamics (tracked extensively during the CPML work) unless something in
        // this capture/render path specifically is wrong.
        if let lastFrame = snapshot.frames.last {
            Self.logEnergyDistribution(frame: lastFrame, nx: nx, ny: ny, zRange: zStart...zEnd,
                                        onBoardMaxEnergy: voxelCachedMaxEnergy)
        }

        updateVoxelColors(forFrame: currentFrameIndex)
    }

    private static func logEnergyDistribution(frame: EMSFieldFrame, nx: Int, ny: Int, zRange: ClosedRange<Int>,
                                                onBoardMaxEnergy: Float) {
        let stride = nx * ny
        let startIndex = zRange.lowerBound * stride
        let endIndex = (zRange.upperBound + 1) * stride
        var countsAboveDB: [Double: Int] = [:]
        // Extended well past -60dB -- distinguishes "energy is everywhere but heavily attenuated"
        // (nonzero out to -150dB/-200dB, just too faint to matter for color) from "energy is exactly
        // zero outside a tiny cluster" (nothing at all past a hard cutoff, however far the threshold
        // is pushed) -- those two would look identical in the original -60dB-floored counts, but
        // imply completely different bugs (a broken/scaled coupling term vs. e.g. a dispatch or
        // capture bug that never touches most cells at all).
        let thresholds: [Double] = [0, -10, -20, -30, -40, -50, -60, -100, -150, -200, -250, -300]
        var totalCells = 0
        var exactlyZeroCells = 0
        var maxIndex = -1
        var maxValue: Float = -.infinity
        frame.cellEnergyData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let floats = buffer.bindMemory(to: Float.self)
            guard floats.count >= endIndex else { return }
            for i in startIndex..<endIndex {
                let v = floats[i]
                totalCells += 1
                if v > maxValue {
                    maxValue = v
                    maxIndex = i
                }
                if v <= 0 {
                    exactlyZeroCells += 1
                    continue
                }
                guard onBoardMaxEnergy > 0 else { continue }
                let db = 10 * log10(Double(v) / Double(onBoardMaxEnergy))
                for threshold in thresholds where db >= threshold {
                    countsAboveDB[threshold, default: 0] += 1
                }
            }
        }
        var maxIx = -1, maxIy = -1, maxIz = -1
        if maxIndex >= 0 {
            let local = maxIndex - startIndex
            maxIz = zRange.lowerBound + local / stride
            let rem = local % stride
            maxIy = rem / nx
            maxIx = rem % nx
        }
        let countsText = thresholds.map { "\($0)dB:\(countsAboveDB[$0] ?? 0)" }.joined(separator: " ")
        let nonzeroCells = totalCells - exactlyZeroCells
        print("[FieldView] energy distribution (last frame, on-board \(totalCells) cells, "
            + "\(nonzeroCells) nonzero, \(exactlyZeroCells) exactly zero): "
            + "peak=\(maxValue) at (ix=\(maxIx),iy=\(maxIy),iz=\(maxIz)) counts-above-threshold: \(countsText)")
    }

    /// Scans every captured frame's own cellEnergyData, but only the cells within `zRange` (the
    /// board-thickness Z crop rebuildVoxelGeometry() already computed) -- see
    /// updateVoxelColors(forFrame:)'s own doc comment for why the color gradient is scaled to this,
    /// not EMSFieldSnapshot.maxCellEnergy (the *whole* mesh's own peak, including the PML/margin
    /// region well outside the board, which can run orders of magnitude higher and would otherwise
    /// make every on-board cell map down near the gradient's dim end regardless of its own real
    /// energy). cellEnergy is z-major (`ix + nx*(iy + ny*iz)`), so each frame's on-board cells form
    /// one contiguous span -- sliced directly rather than decoding/re-copying the whole buffer.
    private static func maxEnergy(in frames: [EMSFieldFrame], nx: Int, ny: Int, zRange: ClosedRange<Int>) -> Float {
        let stride = nx * ny
        let startIndex = zRange.lowerBound * stride
        let endIndex = (zRange.upperBound + 1) * stride
        var result: Float = 0
        for frame in frames {
            frame.cellEnergyData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                let floats = buffer.bindMemory(to: Float.self)
                guard floats.count >= endIndex else { return }
                for i in startIndex..<endIndex {
                    result = max(result, floats[i])
                }
            }
        }
        return result
    }

    /// Recomputes just the per-instance color buffer for one playback frame, reusing the cell-grid
    /// bounds rebuildVoxelGeometry() last cached -- must walk (iz, iy, ix) in that exact same nested
    /// order so instance N here lines up with instance N in voxelGeometryBuffer. This is the entire
    /// per-frame cost of scrubbing/playing back the timeline: no Metal buffer beyond the color one
    /// is touched, and no positions/sizes are recomputed.
    private func updateVoxelColors(forFrame frameIndex: Int) {
        guard let device, let snapshot = fieldSnapshot, let zRange = voxelCachedZRange,
              frameIndex >= 0, frameIndex < snapshot.frames.count else {
            print("[FieldView] updateVoxelColors: bailing, device=\(device != nil) snapshot=\(fieldSnapshot != nil) "
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
            print("[FieldView] updateVoxelColors: bailing, cellEnergy.count=\(cellEnergy.count) "
                + "expected=\(nx * ny * nz) (nx=\(nx) ny=\(ny) nz=\(nz))")
            voxelColorBuffer = nil
            return
        }

        // Scoped to the on-board Z crop (voxelCachedMaxEnergy), not EMSFieldSnapshot.maxCellEnergy's
        // own whole-mesh peak -- see maxEnergy(in:nx:ny:zRange:)'s own doc comment: the PML/margin
        // region well outside the board can carry energy orders of magnitude above anything on the
        // board itself, and scaling against that domain-wide peak made every on-board cell map down
        // near the gradient's dim (blue) end regardless of its own real value.
        let maxEnergy = voxelCachedMaxEnergy
        // 60dB below peak -- the same end-criteria dynamic-range convention already used
        // throughout this run's own progress reporting (see CopperFDTDRunner.cpp's own
        // `endCriteria = 1e-6`), reused here so "the bottom of the gradient" means something the
        // rest of this app's own numbers already established, not an arbitrarily chosen floor.
        // Energy is famously log-distributed spatially, so the gradient is mapped over log10(energy)
        // -- a plain linear min...max mapping would render nearly every cell as the very bottom of
        // the gradient except the single brightest spot, defeating the point of a spatial map. The
        // range is fixed across every frame (voxelCachedMaxEnergy is the run's own on-board peak
        // across every frame, not this one frame's own), so color is comparable across playback
        // rather than each frame independently rescaling to full brightness.
        let floorEnergy = maxEnergy > 0 ? maxEnergy * 1e-6 : 0
        let logMax = log10(max(maxEnergy, Float.leastNormalMagnitude))
        let logFloor = log10(max(floorEnergy, Float.leastNormalMagnitude))
        let logSpan = max(logMax - logFloor, Float.leastNormalMagnitude)

        var colors: [Color4] = []
        colors.reserveCapacity(nx * ny * (zRange.upperBound - zRange.lowerBound + 1))
        for iz in zRange {
            for iy in 0..<ny {
                for ix in 0..<nx {
                    let energy = cellEnergy[ix + nx * iy + energyStride * iz]
                    let logEnergy = log10(max(energy, Float.leastNormalMagnitude))
                    let t = min(max((logEnergy - logFloor) / logSpan, 0), 1)
                    let color = Self.gradientColor(t: t)
                    colors.append(Color4(color.x, color.y, color.z, color.w))
                }
            }
        }

        voxelColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<Color4>.stride * colors.count)
        print("[FieldView] updateVoxelColors: frame=\(frameIndex) built \(colors.count) colors, "
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
