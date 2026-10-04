import Cocoa
import MetalKit
import MetalPerformanceShaders
import QuartzCore

/// Serial, reprioritisable layer tessellation. Keeping only one KiCad extraction in flight bounds
/// peak memory; a newly checked layer jumps ahead of background pre-generation work.
final class BoardLayerGeometryLoader {
    private let load: (String) -> EMSGeometryLayer?
    private weak var view: GeometryView?
    private weak var preview: EMSGeometryPreview?
    private let queue = DispatchQueue(label: "com.kiems.layer-geometry", qos: .utility)
    private var pending: [String]
    private var generated = Set<String>()
    private var running = false
    private var cancelled = false
    private var didDrain = false
    private let onDrained: (() -> Void)?

    init(board: KicadBoardBridge, preview: EMSGeometryPreview, view: GeometryView,
         initiallyVisible: [String], generateAll: Bool = true,
         onDrained: (() -> Void)? = nil) {
        self.load = { try? board.layerPreviewNamed($0) }
        self.onDrained = onDrained
        self.preview = preview
        self.view = view
        let names = preview.layers.filter { !$0.geometryGenerated }.map(\.name)
        let first = initiallyVisible.filter(names.contains)
        self.pending = first + (generateAll ? names.filter { !first.contains($0) } : [])
        view.onLayerNeedsGeometry = { [weak self] name in self?.prioritise(name) }
    }

    init(pipeline: EMSSimulationPipelineBridge, preview: EMSGeometryPreview, view: GeometryView,
         initiallyVisible: [String] = []) {
        self.load = { try? pipeline.geometryLayerNamed($0) }
        self.onDrained = nil
        self.preview = preview
        self.view = view
        let names = preview.layers.filter { !$0.geometryGenerated }.map(\.name)
        let first = initiallyVisible.filter(names.contains)
        self.pending = first + names.filter { !first.contains($0) }
        view.onLayerNeedsGeometry = { [weak self] name in self?.prioritise(name) }
    }

    func start() { queue.async { [weak self] in self?.runNext() } }
    func cancel() {
        queue.async { [weak self] in self?.cancelled = true; self?.pending.removeAll() }
    }
    func prioritise(_ name: String) {
        queue.async { [weak self] in
            guard let self, !generated.contains(name) else { return }
            pending.removeAll { $0 == name }
            pending.insert(name, at: 0)
            runNext()
        }
    }

    private func runNext() {
        guard !cancelled, !running else { return }
        guard !pending.isEmpty else {
            if !didDrain {
                didDrain = true
                if let onDrained { DispatchQueue.main.async(execute: onDrained) }
            }
            return
        }
        didDrain = false
        running = true
        let name = pending.removeFirst()
        if preview?.layers.first(where: { $0.name == name })?.geometryGenerated == true {
            generated.insert(name)
            running = false
            runNext()
            return
        }
        let loaded = load(name)
        if loaded != nil { generated.insert(name) }
        DispatchQueue.main.async { [weak self] in
            guard let self, !cancelled, let loaded, let preview else { return }
            preview.layers.first(where: { $0.name == name })?.replaceTriangles(loaded.triangles)
            view?.refreshLoadedGeometry()
        }
        running = false
        runNext()
    }
}
import simd

/// The user-facing identity returned by GeometryView's picking pass. Zones deliberately never
/// produce one on this screen, while a pin retains its physical identity as well as its net so the
/// configuration sidebar can edit pin-level and net-level settings independently.
struct GeometrySelection: Equatable {
    enum Kind: Equatable {
        case net
        case pin(reference: String, number: String)
        case component(reference: String)
        case hullCutPort(identifier: String)
    }

    let kind: Kind
    let netName: String?
}

/// Simulation-driven highlight state for the whole board: which nets actually take part in the
/// currently selected simulation (a subtle flash), and, among those, which are reachable from a
/// real excitation -- directly, or through a chain of passive (R/L/C) components -- so the flash
/// instead radiates outward from the excitation point as a traveling pulse (see
/// GeometryView.rebuildActivityBuffers() for exactly how). Deliberately geometry-agnostic --
/// WholeBoardViewController (which owns the selected simulation's own config and the board's
/// footprint/pin/net topology) supplies only names/identities here; GeometryView (which owns the
/// real pad positions from its own already-built picking geometry) resolves those into distances.
struct BoardActivityHighlight: Equatable {
    /// One 2-pin passive component bridging two (generally different) nets -- see
    /// WholeBoardViewController's own isPassive()/allFootprints.
    struct PassiveBridge: Equatable {
        let reference: String
        let firstPad: String
        let firstNet: String
        let secondPad: String
        let secondNet: String
    }
    struct ExcitedPin: Equatable {
        let reference: String
        let padNumber: String
        let netName: String
    }
    struct AbsorbingPin: Equatable {
        let reference: String
        let padNumber: String
        let netName: String
    }
    struct ProbedPin: Equatable {
        let reference: String
        let padNumber: String
        let netName: String
    }
    struct HullCutPortSpot: Equatable {
        let identifier: String
        let netName: String
        let position: CGPoint
        let excited: Bool
        let probed: Bool
        let absorbing: Bool
    }
    var includedNets: Set<String> = []
    /// Full simulation nets which seed the distance field used to preview the padded slicing hull.
    /// Geometry-only nets remain visible context but do not expand that hull.
    var hullExpandingNets: Set<String> = []
    /// Per-concrete-net hull expansion in configuration micrometers. A zero-valued entry is still
    /// a contributor; absence means the net is clipped by the hull made by other entries.
    var hullPaddingByNet: [String: Double] = [:]
    var maximumHullPadding: Double? { hullPaddingByNet.values.max() }
    /// Nets whose copper is present at either inclusion level. This drives the muted/non-muted
    /// board colours independently of `includedNets`, which remains the narrower set that receives
    /// the animated simulation-path overlay.
    var configurationIncludedNets: Set<String> = []
    /// Nets that keep their original board colour regardless of ordinary inclusion state. The
    /// selected simulation's concrete ground net is the current member.
    var fullySaturatedNets: Set<String> = []
    /// Footprints with at least one pin on an involved net (or an explicitly selected pin). Their
    /// STEP models and footprint-owned silkscreen stay at full colour; all others are muted.
    var involvedComponentReferences: Set<String> = []
    var excitedPins: [ExcitedPin] = []
    var probedPins: [ProbedPin] = []
    var absorbingPins: [AbsorbingPin] = []
    var hullCutPortSpots: [HullCutPortSpot] = []
    var passiveBridges: [PassiveBridge] = []
    /// R/L/C-prefixed footprints whose Value field cannot produce a usable lumped component.
    /// Component bodies use this warning state; pins deliberately do not, because their colors
    /// already communicate excitation/probe/absorption roles.
    var invalidComponentReferences: Set<String> = []
    /// Setup-screen projection of the Geometry pass's stitching-via decision. These coordinates are
    /// already in the whole-board preview's simulation-unit frame.
    var plannedStitchingViaPositions: [CGPoint] = []
    var rejectedStitchingViaPositions: [CGPoint] = []
    var plannedStitchingViaDiameter: CGFloat = 0
    /// Distinguishes "no simulation selected" from a selected simulation that currently has no
    /// included nets. Only the latter should mute every net on the board.
    var hasSelectedSimulation = false

    /// Everything rebuildBoardBuffers() reads: copper/component muting, the hull seed copper, and
    /// the hull-cut pick discs (by position, not role).
    struct BoardInputs: Equatable {
        var includedNets: Set<String>
        var hullPaddingByNet: [String: Double]
        var configurationIncludedNets: Set<String>
        var fullySaturatedNets: Set<String>
        var involvedComponentReferences: Set<String>
        var invalidComponentReferences: Set<String>
        var passiveBridges: [PassiveBridge]
        var hullCutPickSpots: [String]
        var hasSelectedSimulation: Bool
    }
    var boardInputs: BoardInputs {
        BoardInputs(includedNets: includedNets, hullPaddingByNet: hullPaddingByNet,
                    configurationIncludedNets: configurationIncludedNets,
                    fullySaturatedNets: fullySaturatedNets,
                    involvedComponentReferences: involvedComponentReferences,
                    invalidComponentReferences: invalidComponentReferences,
                    passiveBridges: passiveBridges,
                    hullCutPickSpots: hullCutPortSpots.map {
                        "\($0.identifier)|\($0.netName)|\($0.position.x)|\($0.position.y)"
                    },
                    hasSelectedSimulation: hasSelectedSimulation)
    }

    /// Everything rebuildActivityBuffers() reads beyond boardInputs.
    struct FlowInputs: Equatable {
        var excitedPins: [ExcitedPin]
        var hullExpandingNets: Set<String>
    }
    var flowInputs: FlowInputs { FlowInputs(excitedPins: excitedPins, hullExpandingNets: hullExpandingNets) }
}

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
/// defaulting to a straight top-down view fitted to the board -- an orthographic camera has no
/// perspective foreshortening, so rotating to look straight down any one axis renders exactly as
/// flat/2D as the old top-down-only view this replaces, while every other angle still reads as
/// genuinely 3D.
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
    /// Whole-board consumers can present selection details without knowing about the renderer's
    /// private pick identifiers. Pin selections report their connected net; trace selections
    /// report the selected net directly, as do zone fills; background reports nil.
    var onSelectionChanged: ((GeometrySelection?) -> Void)?
    /// Called when a placeholder layer is made visible, allowing the owner to move that layer to
    /// the front of its serial generation queue.
    var onLayerNeedsGeometry: ((String) -> Void)?

    var preview: EMSGeometryPreview? {
        didSet {
            selectedGridLayerIndex = nil
            selectedTarget = nil
            // Layer names come from KiCad rather than a fixed app-side list. The simulation
            // geometry browser starts with every copper layer visible; the setup screen starts
            // with only the requested fabrication/assembly context layers.
            if preview?.wholeBoard == true, let layers = preview?.layers {
                let initiallyVisible = Set(["F.Cu", "F.Adhesive", "F.Adhes", "F.Mask", "F.Fab", "Edge.Cuts"])
                hiddenLayerIndices = Set(layers.enumerated().compactMap { index, layer in
                    initiallyVisible.contains(layer.name) ? nil : index
                })
            } else {
                hiddenLayerIndices = Set(preview?.layers.enumerated().compactMap { index, layer in
                    layer.name.hasSuffix(".Cu") ? nil : index
                } ?? [])
            }
            // Catalog mask layers own visibility now; legacy detailed previews may still carry the
            // separately blended mask meshes, but drawing those as well would duplicate F/B.Mask.
            hideTopSolderMask = preview?.layers.contains(where: { $0.name == "F.Mask" }) == true
            hideBottomSolderMask = preview?.layers.contains(where: { $0.name == "B.Mask" }) == true
            hideComponents = false
            rebuildBoardBuffers()
            rebuildGridBuffers()
            hasFitCamera = false
            rebuildLegend()
            needsDisplay = true
        }
    }

    /// A layer object was filled in-place, or a detailed preview was merged into the current
    /// catalog. Visibility is deliberately untouched.
    func refreshLoadedGeometry() {
        rebuildBoardBuffers()
        rebuildGridBuffers()
        rebuildLegend()
        needsDisplay = true
    }

    var visibleLayerNames: [String] {
        guard let preview else { return [] }
        return preview.layers.indices.compactMap { hiddenLayerIndices.contains($0) ? nil : preview.layers[$0].name }
    }

    /// Set by WholeBoardViewController whenever the selected simulation (or its involved-nets/
    /// excitations) changes -- nil (or an all-empty value) means no simulation is selected, or none
    /// of its nets are included, so nothing here flashes at all. Drives both the excited-pin red
    /// markers (rebuilt alongside the rest of the board -- see rebuildBoardBuffers()) and the
    /// translucent flashing/ripple overlay (rebuildActivityBuffers()); also starts/stops this view's
    /// own continuous redraw (see updateAnimationState()), since animating anything at all needs a
    /// real per-frame draw loop, unlike every other static-until-interacted-with state here.
    var activity: BoardActivityHighlight? {
        didSet {
            guard activity != oldValue else { return }
            // Most Setup edits (port roles, impedance, planned vias) only move dots. Re-tessellating
            // the board, and re-running the flow-graph search, is reserved for edits that change
            // their own inputs.
            if activity?.boardInputs != oldValue?.boardInputs {
                rebuildBoardBuffers() // Also rebuilds the activity and marker buffers.
            } else {
                if activity?.flowInputs != oldValue?.flowInputs {
                    rebuildActivityBuffers()
                }
                rebuildMarkerBuffers()
            }
            updateAnimationState()
            needsDisplay = true
        }
    }
    private var activityAnimationStartTime: CFTimeInterval?

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

    /// Per-layer visibility, toggled from the legend's own checkboxes (see rebuildLegend()) -- lets
    /// a copper-layer rendering artifact (a wedge, a wrong-colored patch, whatever) be isolated to
    /// one specific layer by hiding every other one, rather than guessing from the combined render.
    /// Indices into `preview.layers`; reset to "everything shown" whenever `preview` changes (see
    /// its own didSet) since a new board's layer count/order isn't guaranteed to line up with the
    /// previous one's.
    private var hiddenLayerIndices: Set<Int> = [] {
        didSet {
            rebuildBoardBuffers()
            needsDisplay = true
        }
    }
    private var hideTopSolderMask = false {
        didSet {
            rebuildBoardBuffers()
            needsDisplay = true
        }
    }
    /// STEP-model visibility, controlled by the Components row in the legend. Component triangles
    /// share the opaque board buffers with pads/tracks rather than having a separate draw call, so
    /// changing this requires rebuilding those buffers.
    private var hideComponents = false {
        didSet {
            guard hideComponents != oldValue else { return }
            rebuildBoardBuffers()
            needsDisplay = true
        }
    }
    private var hideBottomSolderMask = false {
        didSet {
            rebuildBoardBuffers()
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private var commandQueue: MTLCommandQueue!
    private var opaquePipelineState: MTLRenderPipelineState!
    private var unlitPipelineState: MTLRenderPipelineState!
    private var highlightPipelineState: MTLRenderPipelineState!
    private var pickingPipelineState: MTLRenderPipelineState!
    private var activityPipelineState: MTLRenderPipelineState!
    private var regionUnionPipelineState: MTLRenderPipelineState!
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
    /// Same depth behavior as translucentDepthStencilState, plus a one-shot stencil write: the
    /// first selected fragment at a sample blends and increments 0 -> 1; overlapping selected
    /// triangles then fail the stencil comparison instead of blending white repeatedly.
    private var highlightDepthStencilState: MTLDepthStencilState!
    private var pickingDepthStencilState: MTLDepthStencilState!

    // MARK: - Board geometry (layers + vias + ports, one combined opaque triangle buffer)

    private var boardPositionBuffer: MTLBuffer?
    private var boardColorBuffer: MTLBuffer?
    private var boardNormalBuffer: MTLBuffer?
    // Per-vertex region/muting disposition (-1 = involved copper that is always inside the cutout
    // at its own footprint, 0 = follow the region texture, 1 = muted for a net-exclusion or
    // uninvolved-component reason), parallel to boardColorBuffer. Kept separate from baked-in color
    // so geometry_pbr_fragment can combine it with the per-pixel "outside the hull" test before
    // applying mutedSimulationColor's dim once, rather than baking the dim in twice (see
    // updateRegionHighlight(commandBuffer:)'s own doc comment and this feature's origin: the user
    // explicitly asked for exactly this combined behavior, not compounding dims).
    private var boardMuteFlagBuffer: MTLBuffer?
    private var boardVertexCount = 0

    // Port/probe/excitation and planned-via dots -- see rebuildMarkerBuffers(). Same vertex layout
    // as the board buffers, drawn with the same opaque pipeline straight after them.
    private var markerPositionBuffer: MTLBuffer?
    private var markerColorBuffer: MTLBuffer?
    private var markerNormalBuffer: MTLBuffer?
    private var markerMuteFlagBuffer: MTLBuffer?
    private var markerVertexCount = 0

    // Filled copper zones are translucent and drawn before opaque tracks/pads, so the latter stay
    // crisp where they occupy the same physical copper plane.
    private var zonePositionBuffer: MTLBuffer?
    private var zoneColorBuffer: MTLBuffer?
    private var zoneNormalBuffer: MTLBuffer?
    private var zoneMuteFlagBuffer: MTLBuffer?
    private var zoneVertexCount = 0

    // MARK: - Simulation region highlight (exact board-space Euclidean distance transform).

    private var regionSeedPipelineState: MTLRenderPipelineState!
    private var regionDistanceTransform: MPSImageEuclideanDistanceTransform!
    private struct RegionSeedGroup {
        let paddingMicrometers: Double
        let positionBuffer: MTLBuffer
        let vertexCount: Int
    }
    // One group per distinct padding value. Each is distance-transformed independently and then
    // combined into the final union mask, so a 0mm net does not inherit another net's 5mm halo.
    private var regionSeedGroups: [RegionSeedGroup] = []
    private var regionDistanceTextures: (seed: MTLTexture, distance: MTLTexture, union: MTLTexture)?
    private var regionDistanceTextureResolution: (width: Int, height: Int) = (0, 0)
    private var regionWorldMin = SIMD2<Float>.zero
    private var regionWorldInverseSize = SIMD2<Float>.zero
    private var regionWorldPerTexel: Float = 1
    // Board-space rect currently rasterized into the region textures (see updateRegionHighlight).
    private var regionCropMin = SIMD2<Float>.zero
    private var regionCropMax = SIMD2<Float>.zero
    private var regionHighlightNeedsUpdate = true
    // Bound whenever the region highlight is inactive (see GeometryPBRUniformsGPU.regionMaskThreshold's own
    // sentinel) -- geometry_pbr_fragment's texture argument still needs a valid binding even when its
    // sampled value is discarded, so this avoids allocating/tearing down a real region texture pair
    // just to satisfy that.
    private var regionDummyTexture: MTLTexture?

    private enum PickTarget: Hashable {
        case pin(reference: String, number: String, net: String?)
        case net(String)
        case zone(String?)
        case component(String)
        case hullCutPort(identifier: String, net: String)

        var netName: String? {
            switch self {
            case let .pin(_, _, net): return net
            case let .net(net): return net
            case let .zone(net): return net
            case .component: return nil
            case let .hullCutPort(_, net): return net
            }
        }

        /// Pins are submitted after every other pick target in their own depth-biased draw. This
        /// makes a pad win over a nominally coplanar trace without disabling the depth test.
        var hasPickPriority: Bool {
            switch self {
            case .pin, .component, .hullCutPort: return true
            case .net, .zone: return false
            }
        }
    }

    private var pickingPositionBuffer: MTLBuffer?
    private var pickingIdentifierBuffer: MTLBuffer?
    private var pickingVertexCount = 0
    /// First pin vertex in the combined picking buffers. Non-pins are drawn first with ordinary
    /// depth, then pins with a small toward-camera bias so nominally coplanar pads beat
    /// traces without relying on their interpolated depths being bit-for-bit identical.
    private var pickingPriorityVertexStart = 0
    private var pickTargetsByIdentifier: [UInt32: PickTarget] = [:]
    private var pickPositionsByTarget: [PickTarget: [Position3]] = [:]
    private var selectedTarget: PickTarget? {
        didSet {
            rebuildHighlightBuffer()
            let selection: GeometrySelection?
            switch selectedTarget {
            case let .pin(reference, number, net):
                selection = GeometrySelection(kind: .pin(reference: reference, number: number), netName: net)
            case let .net(net):
                selection = GeometrySelection(kind: .net, netName: net)
            case let .component(reference):
                selection = GeometrySelection(kind: .component(reference: reference), netName: nil)
            case let .hullCutPort(identifier, net):
                selection = GeometrySelection(kind: .hullCutPort(identifier: identifier), netName: net)
            case .zone, nil:
                selection = nil
            }
            onSelectionChanged?(selection)
            needsDisplay = true
        }
    }
    private var highlightPositionBuffer: MTLBuffer?
    private var highlightColorBuffer: MTLBuffer?
    private var highlightVertexCount = 0

    // MARK: - Board activity (simulation-included-net flashing / excitation ripple overlay --
    // see BoardActivityHighlight/rebuildActivityBuffers()). Excited-pin red markers are simpler:
    // opaque, static geometry, so they're just appended into the main board buffers above instead
    // of needing their own pipeline/buffers here.

    private var activityPositionBuffer: MTLBuffer?
    private var activityColorBuffer: MTLBuffer?
    private var activityDistanceBuffer: MTLBuffer?
    private var activityVertexCount = 0

    // MARK: - Solder mask (translucent, drawn in its own pass after every opaque draw above)

    private var maskPositionBuffer: MTLBuffer?
    private var maskColorBuffer: MTLBuffer?
    private var maskNormalBuffer: MTLBuffer?
    private var maskMuteFlagBuffer: MTLBuffer?
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
    // At the +Z pole, an azimuth of -90 degrees maps world +X to screen-right and world +Y to
    // screen-up. The orientation remains fully orbitable after this initial top-down framing.
    private var azimuth: Float = -.pi / 2
    private var elevation: Float = .pi / 2
    private var distance: Float = 1
    private var target = Position3(0, 0, 0)
    private var sceneRadius: Float = 1
    private var hasFitCamera = false
    private var lastDragPoint: CGPoint?
    private var mouseDownPoint: CGPoint?
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
        depthStencilPixelFormat = .depth32Float_stencil8
        sampleCount = Self.sampleCount

        if let device {
            commandQueue = device.makeCommandQueue()
            opaquePipelineState = Self.makePBRPipelineState(device: device, pixelFormat: colorPixelFormat,
                                                              translucent: false)
            unlitPipelineState = Self.makePipelineState(device: device, pixelFormat: colorPixelFormat,
                                                          translucent: false)
            highlightPipelineState = Self.makeHighlightPipelineState(device: device, pixelFormat: colorPixelFormat)
            pickingPipelineState = Self.makePickingPipelineState(device: device)
            activityPipelineState = Self.makeActivityPipelineState(device: device, pixelFormat: colorPixelFormat)
            regionSeedPipelineState = Self.makeRegionSeedPipelineState(device: device)
            regionUnionPipelineState = Self.makeRegionUnionPipelineState(device: device)
            regionDistanceTransform = MPSImageEuclideanDistanceTransform(device: device)
            regionDummyTexture = Self.makeRegionDummyTexture(device: device)
            let depthDescriptor = MTLDepthStencilDescriptor()
            // Board layers are submitted back-to-front. `lessEqual` lets the later, upper layer
            // win as intended even when the board is enormous relative to its thickness and two
            // nearby copper sheets quantize to the same depth-buffer value.
            depthDescriptor.depthCompareFunction = .lessEqual
            depthDescriptor.isDepthWriteEnabled = true
            depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)

            let gridDepthDescriptor = MTLDepthStencilDescriptor()
            gridDepthDescriptor.depthCompareFunction = .always
            gridDepthDescriptor.isDepthWriteEnabled = false
            gridDepthStencilState = device.makeDepthStencilState(descriptor: gridDepthDescriptor)

            translucentPipelineState = Self.makePBRPipelineState(device: device, pixelFormat: colorPixelFormat,
                                                                   translucent: true)
            let translucentDepthDescriptor = MTLDepthStencilDescriptor()
            translucentDepthDescriptor.depthCompareFunction = .lessEqual
            translucentDepthDescriptor.isDepthWriteEnabled = false
            translucentDepthStencilState = device.makeDepthStencilState(descriptor: translucentDepthDescriptor)

            let highlightDepthDescriptor = MTLDepthStencilDescriptor()
            highlightDepthDescriptor.depthCompareFunction = .lessEqual
            highlightDepthDescriptor.isDepthWriteEnabled = false
            let highlightStencilDescriptor = MTLStencilDescriptor()
            highlightStencilDescriptor.stencilCompareFunction = .equal
            highlightStencilDescriptor.stencilFailureOperation = .keep
            highlightStencilDescriptor.depthFailureOperation = .keep
            highlightStencilDescriptor.depthStencilPassOperation = .incrementClamp
            highlightStencilDescriptor.readMask = 0xff
            highlightStencilDescriptor.writeMask = 0xff
            highlightDepthDescriptor.frontFaceStencil = highlightStencilDescriptor
            highlightDepthDescriptor.backFaceStencil = highlightStencilDescriptor
            highlightDepthStencilState = device.makeDepthStencilState(descriptor: highlightDepthDescriptor)

            let pickingDepthDescriptor = MTLDepthStencilDescriptor()
            pickingDepthDescriptor.depthCompareFunction = .lessEqual
            pickingDepthDescriptor.isDepthWriteEnabled = true
            pickingDepthStencilState = device.makeDepthStencilState(descriptor: pickingDepthDescriptor)
        }

        setupLegend()
    }

    /// Switches between this view's default (redraw only when needsDisplay is explicitly set --
    /// mouse drag, zoom, ...) and a real continuous redraw loop, the only way to animate anything
    /// here. Only ever runs while there's actually something to animate (activity has an included
    /// net), so the common "nothing selected"/"Geometry tab" cases never pay a continuous-redraw
    /// cost at all. activityAnimationStartTime resets every time animation (re)starts (not once at
    /// init) -- see draw(in:)'s own uniforms.time, which stays relative to it -- so `time` stays a
    /// small, numerically well-behaved value instead of growing across an entire long session.
    private func updateAnimationState() {
        let animating = !(activity?.includedNets.isEmpty ?? true)
        if animating {
            if activityAnimationStartTime == nil {
                activityAnimationStartTime = CACurrentMediaTime()
            }
            preferredFramesPerSecond = 30
            isPaused = false
        } else {
            activityAnimationStartTime = nil
            isPaused = true
        }
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
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
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

    private static func makePBRPipelineState(device: MTLDevice, pixelFormat: MTLPixelFormat,
                                              translucent: Bool) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "geometry_pbr_vertex"),
              let fragmentFunction = library.makeFunction(name: "geometry_pbr_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.rasterSampleCount = sampleCount
        if translucent {
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeHighlightPipelineState(device: MTLDevice,
                                                     pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "geometry_highlight_vertex"),
              let fragmentFunction = library.makeFunction(name: "field_overlay_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makePickingPipelineState(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "geometry_pick_vertex"),
              let fragmentFunction = library.makeFunction(name: "geometry_pick_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .r32Uint
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = 1
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeActivityPipelineState(device: MTLDevice,
                                                    pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "board_activity_vertex"),
              let fragmentFunction = library.makeFunction(name: "board_activity_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Rasterizes included-net copper as non-zero pixels for MPS's exact Euclidean transform.
    private static func makeRegionSeedPipelineState(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "board_region_seed_vertex"),
              let fragmentFunction = library.makeFunction(name: "board_region_seed_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .r8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Thresholds one exact distance field into the accumulated union of all per-net paddings.
    private static func makeRegionUnionPipelineState(device: MTLDevice) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "board_region_union_vertex"),
              let fragmentFunction = library.makeFunction(name: "board_region_union_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .r8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .max
        descriptor.colorAttachments[0].alphaBlendOperation = .max
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// A 1x1 stand-in for geometry_pbr_fragment's region-texture argument whenever the real
    /// region texture isn't available (the highlight is off, or this configuration has nothing to
    /// seed from) -- its own value is never actually read in that case (see
    /// GeometryPBRUniformsGPU.regionMaskThreshold's own sentinel), this just keeps the binding valid.
    private static func makeRegionDummyTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var zero: UInt8 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero,
                         bytesPerRow: MemoryLayout<UInt8>.stride)
        return texture
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let commandQueue, let opaquePipelineState, let unlitPipelineState,
              let depthStencilState, let gridDepthStencilState,
              let drawable = currentDrawable, let descriptor = currentRenderPassDescriptor else { return }
        resetCameraIfNeeded()

        descriptor.colorAttachments[0].clearColor = Self.backgroundColor
        descriptor.depthAttachment.clearDepth = 1.0
        descriptor.stencilAttachment.loadAction = .clear
        descriptor.stencilAttachment.storeAction = .dontCare
        descriptor.stencilAttachment.clearStencil = 0

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Region-highlight passes are their own separate offscreen render encoders on this same
        // command buffer -- must be encoded (and ended) before the main scene encoder below, since a
        // texture written by one encoder can't also be bound for reading by another that's
        // simultaneously open. See updateRegionHighlight(commandBuffer:)'s own doc comment.
        let regionTexture = updateRegionHighlight(commandBuffer: commandBuffer)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let eye = currentEyePosition()
        let viewProjection = currentProjectionMatrix() * lookAt(
            eye: eye, center: SIMD3(target.x, target.y, target.z),
            up: -currentOrientation().act(SIMD3<Float>(1, 0, 0)))
        var uniforms = FieldUniformsGPU(viewProjection: viewProjection,
                                         time: Float(CACurrentMediaTime() - (activityAnimationStartTime ?? CACurrentMediaTime())))
        var pbrUniforms = GeometryPBRUniformsGPU(
            viewProjection: viewProjection,
            cameraPosition: SIMD4<Float>(eye.x, eye.y, eye.z, 1),
            // A broad key from the upper-right of the default isometric view. Material roughness
            // in the PBR shader spreads its response across the board instead of creating the
            // tight lower-right highlight the original key produced.
            lightDirection: SIMD4<Float>(-0.30, -0.35, -0.88, 0),
            regionWorldMin: regionWorldMin,
            regionWorldInverseSize: regionWorldInverseSize,
            regionMaskThreshold: regionTexture != nil ? 0.5 : -1)
        let regionTextureToBind = regionTexture ?? regionDummyTexture

        encoder.setVertexBytes(&pbrUniforms, length: MemoryLayout<GeometryPBRUniformsGPU>.stride, index: 3)
        encoder.setFragmentBytes(&pbrUniforms, length: MemoryLayout<GeometryPBRUniformsGPU>.stride, index: 3)
        encoder.setFragmentTexture(regionTextureToBind, index: 0)

        encoder.setRenderPipelineState(opaquePipelineState)
        encoder.setDepthStencilState(depthStencilState)

        // Real depth test/write for opaque board geometry (see depthStencilState's own doc comment)
        // -- draw order below doesn't affect its correctness. The diagnostic grid switches to its
        // own depth-free overlay state immediately before it is drawn.
        if boardVertexCount > 0, let positions = boardPositionBuffer, let colors = boardColorBuffer,
           let normals = boardNormalBuffer, let muteFlags = boardMuteFlagBuffer {
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.setVertexBuffer(normals, offset: 0, index: 2)
            encoder.setVertexBuffer(muteFlags, offset: 0, index: 4)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: boardVertexCount)
        }
        if markerVertexCount > 0, let positions = markerPositionBuffer, let colors = markerColorBuffer,
           let normals = markerNormalBuffer, let muteFlags = markerMuteFlagBuffer {
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.setVertexBuffer(normals, offset: 0, index: 2)
            encoder.setVertexBuffer(muteFlags, offset: 0, index: 4)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: markerVertexCount)
        }
        // Pours are also stored back-to-front. Draw them over the completed opaque stack so an
        // upper-layer pour correctly blends over lower copper; their tiny rearward Z offset (set
        // while building the buffers) keeps same-layer tracks and pads crisp on top.
        if zoneVertexCount > 0, let positions = zonePositionBuffer, let colors = zoneColorBuffer,
           let normals = zoneNormalBuffer, let muteFlags = zoneMuteFlagBuffer,
           let translucentPipelineState, let translucentDepthStencilState {
            encoder.setRenderPipelineState(translucentPipelineState)
            encoder.setDepthStencilState(translucentDepthStencilState)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.setVertexBuffer(normals, offset: 0, index: 2)
            encoder.setVertexBuffer(muteFlags, offset: 0, index: 4)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: zoneVertexCount)
        }
        encoder.setRenderPipelineState(unlitPipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 2)
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
           let normals = maskNormalBuffer, let muteFlags = maskMuteFlagBuffer,
           let translucentPipelineState, let translucentDepthStencilState {
            encoder.setRenderPipelineState(translucentPipelineState)
            encoder.setDepthStencilState(translucentDepthStencilState)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.setVertexBuffer(normals, offset: 0, index: 2)
            encoder.setVertexBuffer(muteFlags, offset: 0, index: 4)
            encoder.setVertexBytes(&pbrUniforms, length: MemoryLayout<GeometryPBRUniformsGPU>.stride, index: 3)
            encoder.setFragmentBytes(&pbrUniforms, length: MemoryLayout<GeometryPBRUniformsGPU>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: maskVertexCount)
        }

        // Simulation-activity flash/ripple, drawn before the click-selection highlight below so an
        // actively-inspected net's own (static, white) selection tint stays legible on top of it
        // where the two overlap. Plain depth test only (translucentDepthStencilState, not the
        // highlight pass's own stencil-coalesced one) -- an occasional double-brightened seam where
        // two of a net's own triangles touch is an acceptable cosmetic cost for not needing a
        // second dedicated stencil pass just for this.
        if activityVertexCount > 0, let positions = activityPositionBuffer, let colors = activityColorBuffer,
           let distances = activityDistanceBuffer, let activityPipelineState, let translucentDepthStencilState {
            encoder.setRenderPipelineState(activityPipelineState)
            encoder.setDepthStencilState(translucentDepthStencilState)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 2)
            // board_activity_fragment also reads uniforms.time -- unlike every other shader here,
            // whose fragment stage never needs the uniforms buffer, so this is the one draw call
            // that needs it bound on both stages, not just the vertex one above.
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 2)
            encoder.setVertexBuffer(distances, offset: 0, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: activityVertexCount)
        }

        // Selection is a final, unlit UI overlay. It still depth-tests against the opaque board so
        // hidden layers do not shine through, but is submitted after mask so the selected copper
        // remains legible beneath a translucent solder-mask sheet.
        if highlightVertexCount > 0, let positions = highlightPositionBuffer,
           let colors = highlightColorBuffer, let highlightPipelineState,
           let highlightDepthStencilState {
            encoder.setRenderPipelineState(highlightPipelineState)
            encoder.setDepthStencilState(highlightDepthStencilState)
            encoder.setStencilReferenceValue(0)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(colors, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: highlightVertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Simulation region highlight

    /// SimulationConfig's own length-like fields (hullPadding included) are stored in micrometers
    /// (kiems::constants::baseUnit), not the 0.1-micron "simulation units" every position/distance
    /// in this view is in (kiems::constants::unitMultiplier) -- board_slicing.cpp and friends scale
    /// by this same factor (`mm / 1000 / baseUnit * unitMultiplier`) before comparing a micrometer
    /// config value against sim-unit geometry; hullPadding needs the identical scaling before it can
    /// be compared against this view's own computed world-space distances, or it reads 10x too small
    /// (matches: a "5mm" padding was rendering as ~0.5mm).
    private static let simUnitsPerMicrometer: Double = 10

    /// Builds the union of each contributing net's independently padded region. The seed view is an
    /// orthographic top-down view expanded by the largest padding, rather than the visible camera,
    /// so panning/orbiting cannot alter the result. Each distinct padding group gets an exact MPS
    /// distance transform, which is thresholded into a shared mask before the next group reuses the
    /// scratch textures. The textures cover only the on-screen part of that padded board (plus
    /// margin), so zooming in spends their resolution on what's visible.
    private func updateRegionHighlight(commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let device, let preview, let regionSeedPipelineState, let regionUnionPipelineState,
              let regionDistanceTransform, let hullPadding = activity?.maximumHullPadding,
              !regionSeedGroups.isEmpty else { return nil }

        let padding = max(Float(hullPadding * Self.simUnitsPerMicrometer), 0)
        let paddedBoardMin = SIMD2<Float>(Float(preview.xMin) - padding, Float(preview.yMin) - padding)
        let paddedBoardMax = SIMD2<Float>(Float(preview.xMin + preview.width) + padding,
                                          Float(preview.yMin + preview.height) + padding)
        // Only the on-screen part of the board is rasterized. The crop keeps a further `padding`
        // margin around the visible area so seeds just off screen still reach visible texels
        // through the distance transform; anything farther out can't affect what's visible.
        var cropMin = paddedBoardMin, cropMax = paddedBoardMax
        if let visible = visibleBoardRect() {
            cropMin = simd_max(cropMin, visible.min - padding)
            cropMax = simd_min(cropMax, visible.max + padding)
        }
        guard cropMax.x > cropMin.x, cropMax.y > cropMin.y else { return nil }

        // Reuse the current crop while it still covers what's needed at a comparable texel size,
        // so small pans/zooms don't re-run the transform every frame. Otherwise re-crop with some
        // slack around the needed rect (clamped to the padded board) for the same reason.
        let neededSize = cropMax - cropMin
        let idealWorldPerTexel = max(neededSize.x, neededSize.y, 1) / Self.regionTextureMaxDimension
        let covered = regionCropMin.x <= cropMin.x && regionCropMin.y <= cropMin.y
            && regionCropMax.x >= cropMax.x && regionCropMax.y >= cropMax.y
        let texelRatio = regionWorldPerTexel / idealWorldPerTexel
        if !covered || texelRatio > 1.5 || texelRatio < 0.5 {
            let slack = neededSize * 0.25
            regionCropMin = simd_max(paddedBoardMin, cropMin - slack)
            regionCropMax = simd_min(paddedBoardMax, cropMax + slack)
            regionHighlightNeedsUpdate = true
        }
        let cropWidth = regionCropMax.x - regionCropMin.x
        let cropHeight = regionCropMax.y - regionCropMin.y
        let layout = Self.regionTextureLayout(worldWidth: cropWidth, worldHeight: cropHeight)
        let resolution = layout.resolution
        if regionDistanceTextureResolution != resolution {
            regionDistanceTextures = Self.makeRegionTexturePair(device: device, resolution: resolution)
            regionDistanceTextureResolution = resolution
            regionHighlightNeedsUpdate = true
        }
        guard let textures = regionDistanceTextures else { return nil }

        let actualWidth = Float(resolution.width) * layout.worldPerTexel
        let actualHeight = Float(resolution.height) * layout.worldPerTexel
        regionWorldMin = SIMD2<Float>(
            regionCropMin.x - (actualWidth - cropWidth) * 0.5,
            regionCropMin.y - (actualHeight - cropHeight) * 0.5)
        regionWorldInverseSize = SIMD2<Float>(1 / actualWidth, 1 / actualHeight)
        regionWorldPerTexel = layout.worldPerTexel

        guard regionHighlightNeedsUpdate else { return textures.union }

        var seedUniforms = RegionSeedUniformsGPU(
            worldMin: regionWorldMin, worldInverseSize: regionWorldInverseSize)
        for (index, group) in regionSeedGroups.enumerated() {
            let seedPass = MTLRenderPassDescriptor()
            seedPass.colorAttachments[0].texture = textures.seed
            seedPass.colorAttachments[0].loadAction = .clear
            seedPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            seedPass.colorAttachments[0].storeAction = .store
            guard let seedEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: seedPass) else { return nil }
            seedEncoder.setRenderPipelineState(regionSeedPipelineState)
            seedEncoder.setVertexBuffer(group.positionBuffer, offset: 0, index: 0)
            seedEncoder.setVertexBytes(&seedUniforms, length: MemoryLayout<RegionSeedUniformsGPU>.stride, index: 2)
            seedEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: group.vertexCount)
            seedEncoder.endEncoding()

            let groupPadding = max(Float(group.paddingMicrometers * Self.simUnitsPerMicrometer), 0)
            // Limiting the exact search just past this group's threshold preserves correctness while
            // substantially reducing MPS's internal pass count.
            regionDistanceTransform.searchLimitRadius = max(groupPadding / layout.worldPerTexel + 2, 32)
            regionDistanceTransform.encode(commandBuffer: commandBuffer, sourceTexture: textures.seed,
                                           destinationTexture: textures.distance)

            var unionUniforms = RegionUnionUniformsGPU(paddingPixels: groupPadding / layout.worldPerTexel)
            let unionPass = MTLRenderPassDescriptor()
            unionPass.colorAttachments[0].texture = textures.union
            unionPass.colorAttachments[0].loadAction = index == 0 ? .clear : .load
            unionPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            unionPass.colorAttachments[0].storeAction = .store
            guard let unionEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: unionPass) else { return nil }
            unionEncoder.setRenderPipelineState(regionUnionPipelineState)
            unionEncoder.setFragmentBytes(&unionUniforms,
                                          length: MemoryLayout<RegionUnionUniformsGPU>.stride, index: 0)
            unionEncoder.setFragmentTexture(textures.distance, index: 0)
            unionEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            unionEncoder.endEncoding()
        }
        regionHighlightNeedsUpdate = false
        return textures.union
    }

    private static let regionTextureMaxDimension: Float = 4096

    /// The board-plane XY bounding box of everything currently on screen, found by casting the
    /// viewport's corner rays (parallel, since the camera is orthographic) onto the lowest and
    /// highest copper layers. Nil when the view is too close to edge-on for that to be bounded,
    /// in which case the caller falls back to the whole board.
    private func visibleBoardRect() -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let preview else { return nil }
        let forward = -eyeOffsetDirection()
        guard abs(forward.z) > 0.05 else { return nil }
        let zValues = preview.layers.map { Float($0.z) }
        let zRange = [zValues.min() ?? 0, zValues.max() ?? 0]
        let aspect = Float(max(drawableSize.width, 1) / max(drawableSize.height, 1))
        let halfHeight = distance * 0.4
        let halfWidth = halfHeight * aspect
        let (right, up) = cameraRightAndUp()
        let center = SIMD3<Float>(target.x, target.y, target.z)
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for sx: Float in [-1, 1] {
            for sy: Float in [-1, 1] {
                let origin = center + right * (sx * halfWidth) + up * (sy * halfHeight)
                for z in zRange {
                    let hit = origin + forward * ((z - origin.z) / forward.z)
                    lo = simd_min(lo, SIMD2(hit.x, hit.y))
                    hi = simd_max(hi, SIMD2(hit.x, hit.y))
                }
            }
        }
        return (lo, hi)
    }

    private static func regionTextureLayout(worldWidth: Float, worldHeight: Float)
        -> (resolution: (width: Int, height: Int), worldPerTexel: Float) {
        let worldPerTexel = max(worldWidth, worldHeight, 1) / regionTextureMaxDimension
        return ((max(Int(ceil(worldWidth / worldPerTexel)), 1),
                 max(Int(ceil(worldHeight / worldPerTexel)), 1)), worldPerTexel)
    }

    private static func makeRegionTexturePair(device: MTLDevice,
                                               resolution: (width: Int, height: Int))
        -> (seed: MTLTexture, distance: MTLTexture, union: MTLTexture)? {
        let seedDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: resolution.width, height: resolution.height, mipmapped: false)
        seedDescriptor.usage = [.renderTarget, .shaderRead]
        seedDescriptor.storageMode = .private
        let distanceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: resolution.width, height: resolution.height, mipmapped: false)
        distanceDescriptor.usage = [.shaderRead, .shaderWrite]
        distanceDescriptor.storageMode = .private
        let unionDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: resolution.width, height: resolution.height, mipmapped: false)
        unionDescriptor.usage = [.renderTarget, .shaderRead]
        unionDescriptor.storageMode = .private
        guard let a = device.makeTexture(descriptor: seedDescriptor),
              let b = device.makeTexture(descriptor: distanceDescriptor),
              let c = device.makeTexture(descriptor: unionDescriptor) else { return nil }
        return (a, b, c)
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
        // Bracket near/far around a *fixed* half-range -- the scene's own real depth extent
        // (sceneRadius, set once by resetCameraIfNeeded() and never shrunk by zoom) -- rather than
        // a range that shrinks along with `distance` as the camera zooms in. An earlier version
        // additionally capped this range at `min(sceneRadius, distance)`, copied from FieldView's
        // own *perspective* camera, where that keeps the far/near *ratio* bounded to avoid
        // z-fighting far from the camera. This camera is orthographic, where depth precision is
        // linear in the *range*, not the ratio -- that cap only ever shrank the clip volume without
        // helping precision, and once `distance` (zoomed in close, e.g. to select a small pad) fell
        // below any real 3D geometry's own depth extent near the target -- a via barrel, a STEP
        // component model with real height -- that geometry fell outside the near/far planes and
        // disappeared entirely.
        let halfDepthRange = max(sceneRadius * 1.5, 0.001)
        let near = max(distance - halfDepthRange, 0.001)
        let far = distance + halfDepthRange
        // Orthographic camera, not perspective (see this view's own top comment)
        // -- `distance` still drives the ortho window's own size, rather than a separate zoom
        // variable, so the scroll/magnify handlers below (borrowed from FieldView) work unchanged;
        // 0.8 defines the zoom scale used both here and by resetCameraIfNeeded()'s exact fit.
        let height = distance * 0.8
        let width = height * aspect
        return orthographic(width: width, height: height, near: near, far: far)
    }

    // MARK: - Fit-to-view / orbit / zoom

    private func resetCameraIfNeeded() {
        guard !hasFitCamera else { return }
        guard let box = currentBoundingBox() else { return }
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }

        // Start each newly loaded preview square-on. Keeping this here rather than only in the
        // property initializers also resets a view that the user orbited before loading a new board.
        azimuth = -.pi / 2
        elevation = .pi / 2
        target = Position3((box.minX + box.maxX) / 2, (box.minY + box.maxY) / 2, (box.minZ + box.maxZ) / 2)
        let width = max(box.maxX - box.minX, 0.001)
        let height = max(box.maxY - box.minY, 0.001)
        let depth = max(box.maxZ - box.minZ, 0)
        let diagonal = sqrt(width * width + height * height + depth * depth)
        sceneRadius = max(diagonal / 2, 0.001)

        // currentProjectionMatrix() makes the visible height `distance * 0.8`. Fit whichever
        // board dimension constrains the current viewport, then leave a modest margin so copper
        // and component edges do not touch the window border. Distance must also put the camera
        // above the tallest included STEP geometry; unlike perspective, increasing it here only
        // affects scale through that explicit 0.8 relationship.
        let aspect = Float(drawableSize.width / drawableSize.height)
        let fittedVisibleHeight = max(height, width / max(aspect, 0.001))
        let fitDistance = fittedVisibleHeight * 1.08 / 0.8
        let depthClearance = depth * 0.55 + 0.001
        distance = max(fitDistance, depthClearance)
        hasFitCamera = true
    }

    private func currentBoundingBox() -> (minX: Float, maxX: Float, minY: Float, maxY: Float, minZ: Float,
                                           maxZ: Float)? {
        guard let preview, preview.width > 0, preview.height > 0 else { return nil }
        var minX = Float(preview.xMin)
        var maxX = minX + Float(preview.width)
        var minY = Float(preview.yMin)
        var maxY = minY + Float(preview.height)
        // Start with the board's own real layer Z extent (see EMSGeometryLayer.z's own doc comment), not
        // pmlInnerZMin/Max (now "board + real margin," ~2mm past the board on each side -- see that
        // property's own doc comment -- comfortably wider than the board itself) and not
        // gridLinesZ's own min/max (the *full* FDTD domain, PML band included, wider still).
        // Fitting the camera to either would leave the actual board a small sliver in the middle of
        // the view. Matches X/Y's own precedent just above (fit to preview.xMin/width, the board's
        // own box, not the grid's). All-zero (a flat board) if there are no layers yet.
        let zValues = preview.layers.map { Float($0.z) }
        var minZ = zValues.min() ?? 0
        var maxZ = zValues.max() ?? 0
        // STEP models can extend beyond the board outline and, by definition, well above/below its
        // copper stack. Include them in the initial camera fit and clipping range.
        for triangle in preview.componentMeshTriangles {
            for point in [triangle.a, triangle.b, triangle.c] {
                minX = min(minX, Float(point.x))
                maxX = max(maxX, Float(point.x))
                minY = min(minY, Float(point.y))
                maxY = max(maxY, Float(point.y))
                minZ = min(minZ, Float(point.z))
                maxZ = max(maxZ, Float(point.z))
            }
        }
        return (minX, maxX, minY, maxY, minZ, maxZ)
    }

    /// Orbit: drag left/right to rotate azimuth, up/down to tilt elevation -- see azimuth's own doc
    /// comment for why this is unclamped (no gimbal lock) despite being plain Euler angles. Right-
    /// drag pans instead (see rightMouseDragged(_:)), shifting the orbit target itself rather than
    /// orbiting around it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastDragPoint = point
        mouseDownPoint = point
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
        let point = convert(event.locationInWindow, from: nil)
        if let mouseDownPoint, hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) <= 3 {
            pick(at: point)
        }
        lastDragPoint = nil
        mouseDownPoint = nil
    }

    /// Renders the visible pickable copper into an integer off-screen target and reads only the
    /// clicked pixel. The pass uses the same camera and depth rules as the visible board, but a
    /// one-pixel scissor keeps a click proportional to one fragment rather than the whole window.
    private func pick(at point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else {
            selectedTarget = nil
            return
        }
        resetCameraIfNeeded()

        // Hull-cut candidates are UI controls over the board, rather than board geometry. Resolve
        // their screen-space hit discs first -- including inactive candidates with no visible role
        // marker -- so an exactly coincident trace cannot win the depth-buffer ID pass. Keep a
        // small minimum radius when the whole board is fitted on screen.
        if let target = hullCutPortTarget(at: point) {
            selectedTarget = target
            return
        }

        guard let device, let commandQueue, let pickingPipelineState, let pickingDepthStencilState,
              let positions = pickingPositionBuffer, let identifiers = pickingIdentifierBuffer,
              pickingVertexCount > 0 else {
            selectedTarget = nil
            return
        }

        let pixelWidth = max(Int(drawableSize.width), 1)
        let pixelHeight = max(Int(drawableSize.height), 1)
        let pixelX = min(max(Int(point.x / bounds.width * CGFloat(pixelWidth)), 0), pixelWidth - 1)
        let pointFromTop = isFlipped ? point.y : bounds.height - point.y
        let pixelY = min(max(Int(pointFromTop / bounds.height * CGFloat(pixelHeight)), 0), pixelHeight - 1)

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Uint, width: pixelWidth, height: pixelHeight, mipmapped: false)
        colorDescriptor.usage = .renderTarget
        colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: pixelWidth, height: pixelHeight, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor),
              let depthTexture = device.makeTexture(descriptor: depthDescriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let eye = currentEyePosition()
        var uniforms = FieldUniformsGPU(viewProjection: currentProjectionMatrix() * lookAt(
            eye: eye, center: SIMD3(target.x, target.y, target.z),
            up: -currentOrientation().act(SIMD3<Float>(1, 0, 0))))
        encoder.setRenderPipelineState(pickingPipelineState)
        encoder.setDepthStencilState(pickingDepthStencilState)
        encoder.setScissorRect(MTLScissorRect(x: pixelX, y: pixelY, width: 1, height: 1))
        encoder.setVertexBuffer(positions, offset: 0, index: 0)
        encoder.setVertexBuffer(identifiers, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FieldUniformsGPU>.stride, index: 2)
        let priorityStart = min(pickingPriorityVertexStart, pickingVertexCount)
        if priorityStart > 0 {
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: priorityStart)
        }
        if priorityStart < pickingVertexCount {
            // Standard depth increases away from this camera (`lessEqual` wins), so a negative
            // constant bias moves the pin slightly toward it. This resolves tiny rasterized
            // differences between otherwise coplanar pad/trace triangles, while the normal depth
            // test still rejects a pin behind meaningfully nearer geometry.
            encoder.setDepthBias(-1, slopeScale: 0, clamp: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: priorityStart,
                                   vertexCount: pickingVertexCount - priorityStart)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var identifier: UInt32 = 0
        colorTexture.getBytes(&identifier, bytesPerRow: MemoryLayout<UInt32>.stride,
                              from: MTLRegionMake2D(pixelX, pixelY, 1, 1), mipmapLevel: 0)
        guard let picked = pickTargetsByIdentifier[identifier] else {
            selectedTarget = nil
            return
        }
        // Clicking a zone fill selects its net, exactly as clicking one of the net's traces does.
        // Unconnected (no-net) pours have nothing to select.
        if case let .zone(net) = picked {
            if let net, !net.isEmpty {
                selectedTarget = .net(net)
            } else {
                selectedTarget = nil
            }
        } else {
            selectedTarget = picked
        }
    }

    private func hullCutPortTarget(at point: CGPoint) -> PickTarget? {
        guard let preview, let spots = activity?.hullCutPortSpots, !spots.isEmpty,
              bounds.width > 0, bounds.height > 0 else { return nil }

        let eye = currentEyePosition()
        let viewProjection = currentProjectionMatrix() * lookAt(
            eye: eye, center: SIMD3(target.x, target.y, target.z),
            up: -currentOrientation().act(SIMD3<Float>(1, 0, 0)))
        let layerZValues = preview.layers.map { Float($0.z) }
        let topZ = layerZValues.max() ?? 0
        let bottomZ = layerZValues.min() ?? 0
        let markerZ = topZ + max(topZ - bottomZ, 1) * 0.01

        func project(_ world: Position3) -> (point: CGPoint, depth: Float)? {
            let clip = viewProjection * SIMD4<Float>(world.x, world.y, world.z, 1)
            guard abs(clip.w) > 1e-8 else { return nil }
            let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
            guard ndc.z >= 0, ndc.z <= 1 else { return nil }
            let x = CGFloat((ndc.x + 1) * 0.5) * bounds.width
            let bottomOriginY = CGFloat((ndc.y + 1) * 0.5) * bounds.height
            let y = isFlipped ? bounds.height - bottomOriginY : bottomOriginY
            return (CGPoint(x: x, y: y), ndc.z)
        }

        var best: (target: PickTarget, distance: CGFloat, depth: Float)?
        for spot in spots {
            let centerWorld = Position3(Float(spot.position.x), Float(spot.position.y), markerZ)
            guard let center = project(centerWorld) else { continue }
            let radius = Float(Self.absorbingPinMarkerRadius)
            let projectedX = project(Position3(centerWorld.x + radius, centerWorld.y, centerWorld.z))?.point
            let projectedY = project(Position3(centerWorld.x, centerWorld.y + radius, centerWorld.z))?.point
            let xRadius: CGFloat = projectedX.map {
                hypot($0.x - center.point.x, $0.y - center.point.y)
            } ?? 0
            let yRadius: CGFloat = projectedY.map {
                hypot($0.x - center.point.x, $0.y - center.point.y)
            } ?? 0
            let projectedRadius: CGFloat = max(6, max(xRadius, yRadius))
            let distance = hypot(point.x - center.point.x, point.y - center.point.y)
            guard distance <= projectedRadius else { continue }
            let candidate = PickTarget.hullCutPort(identifier: spot.identifier, net: spot.netName)
            if best == nil || distance < best!.distance ||
                (distance == best!.distance && center.depth < best!.depth) {
                best = (candidate, distance, center.depth)
            }
        }
        return best?.target
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
    // A non-loading measurement point -- a pin-level passive probe or a net-level trace-impedance
    // probe alike (see EMSGeometryPort.absorbSignal's own doc comment) -- has zero effect on the
    // simulated fields, unlike a real terminating port; distinct from portColor so that difference
    // is visible at a glance in the preview.
    private static let probeColor = SIMD4<Float>(Float(NSColor.systemOrange.usingColorSpace(.deviceRGB)?.redComponent ?? 1.0),
                                                    Float(NSColor.systemOrange.usingColorSpace(.deviceRGB)?.greenComponent ?? 0.58),
                                                    Float(NSColor.systemOrange.usingColorSpace(.deviceRGB)?.blueComponent ?? 0.0),
                                                    1)
    // Solid red -- distinct from every other marker/copper color in this view -- marking a pin
    // with a real ExcitationConfig in the currently selected simulation (see
    // BoardActivityHighlight.ExcitedPin's own doc comment).
    private static let excitedPinColor = SIMD4<Float>(1, 0.15, 0.15, 1)
    // Measured pins are yellow. Kept separate from probeColor because that existing orange is also
    // used for non-pin geometry-preview ports, whereas this is specifically a board pin marker.
    private static let probedPinColor = SIMD4<Float>(1, 0.82, 0.08, 1)
    // Absorbing/terminating pins use the conventional port blue. They are appended before
    // excitation markers below, so a driven pin (which is inherently terminating too) remains
    // unambiguously red when both identities refer to the same physical pad.
    private static let absorbingPinColor = portColor
    // The yellow/red centres are deliberately smaller than the blue absorbing disc. Consequently
    // probe+absorb reads as yellow with a blue border, and excite+absorb as red with a blue border.
    // Dimensions are world-space sim units (10000/mm), matching every other board marker here.
    private static let excitedPinMarkerRadius: CGFloat = 1600
    private static let probedPinMarkerRadius: CGFloat = 1600
    private static let absorbingPinMarkerRadius: CGFloat = 2000
    /// Applies the warning treatment to the model's original material: boost its brightness by
    /// 30%, then blend strongly toward saturated red. Retaining some of the material color keeps
    /// the model's shading and part boundaries readable instead of replacing it with a flat mask.
    private static func invalidComponentColor(_ color: SIMD4<Float>) -> SIMD4<Float> {
        let boosted = SIMD3<Float>(min(color.x * 1.3, 1), min(color.y * 1.3, 1), min(color.z * 1.3, 1))
        let tinted = boosted * 0.3 + SIMD3<Float>(1, 0, 0) * 0.7
        return SIMD4<Float>(tinted.x, tinted.y, tinted.z, color.w)
    }
    // A soft cyan-white -- distinct from the click-selection highlight's own plain white (see
    // rebuildHighlightBuffer()) so "this net is live in the simulation" never reads as "this is
    // what you clicked."
    private static let activityColor = SIMD4<Float>(0.55, 1.0, 0.92, 1)
    // A fixed light grey, not the adaptive tertiaryLabelColor the outline used to use -- that
    // reads as near-invisible against the fixed dark canvas below in light-appearance mode.
    private static let outlineColor = SIMD4<Float>(0.7, 0.7, 0.7, 1)
    // A classic PCB solder-mask green -- distinct from every copper color in kicadDefaultLayerColors
    // (all coppery/metallic tones) so the mask reads as its own material, not another copper layer.
    // 50% alpha (drawn via translucentPipelineState, not the opaque one every other color here
    // uses) so the copper/silkscreen underneath stays visible, matching a real solder mask's own
    // partial translucency.
    private static let solderMaskColor = SIMD4<Float>(0.0, 0.35, 0.16, 0.5)
    /// Same color as solderMaskColor, as an NSColor for the legend swatch (an NSBox's fillColor,
    /// unlike a Metal vertex color, so this can't just reuse the SIMD4 directly).
    private static let solderMaskLegendColor = NSColor(deviceRed: 0.0, green: 0.35, blue: 0.16, alpha: 0.5)
    // A muted cyan -- distinct from the plain grey outline/legend text and every copper color in
    // kicadDefaultLayerColors, so a mesh line stays identifiable crossing any layer's fill.
    private static let gridLineColor = SIMD4<Float>(0.3, 0.75, 0.8, 1)
    // A dim magenta -- distinct from the cyan core-mesh color above, marking the real CPML cells.
    // In X/Y those now follow Copper's hull-offset domain mask rather than the old rectangular
    // pmlInner bounds; in Z the top/bottom bands remain conventional slabs. External X/Y edges are
    // omitted from the buffers altogether, so empty work outside the CPML is visibly empty too.
    private static let pmlLineColor = SIMD4<Float>(0.85, 0.25, 0.85, 1)
    // Solid black -- distinct from every other marker color here (copper fills, gold via stroke,
    // blue ports), reads unambiguously as "nothing was placed here" rather than another kind of
    // real geometry.
    private static let failedViaAttemptColor = SIMD4<Float>(0, 0, 0, 1)
    private static let plannedViaColor = SIMD4<Float>(0xC6 / 255.0, 0x9B / 255.0, 0x3C / 255.0, 1)
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
        regionHighlightNeedsUpdate = true
        guard let device, let preview else {
            boardVertexCount = 0
            zoneVertexCount = 0
            pickingVertexCount = 0
            pickingPriorityVertexStart = 0
            pickTargetsByIdentifier = [:]
            pickPositionsByTarget = [:]
            highlightVertexCount = 0
            activityPositionBuffer = nil
            activityColorBuffer = nil
            activityDistanceBuffer = nil
            activityVertexCount = 0
            outlineVertexCount = 0
            crossVertexCount = 0
            markerVertexCount = 0
            maskVertexCount = 0
            regionSeedGroups = []
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
        var normals: [Position3] = []
        var muteFlags: [Float] = []
        var zonePositions: [Position3] = []
        var zoneColors: [SIMD4<Float>] = []
        var zoneNormals: [Position3] = []
        var zoneMuteFlags: [Float] = []
        // Simulation-net copper grouped by its own padding, rasterized into a camera-independent
        // board-space mask when these buffers change.
        var regionSeedPositionsByPadding: [Double: [Position3]] = [:]
        var pickingPositions: [Position3] = []
        var pickingIdentifiers: [UInt32] = []
        // Pins are appended to the combined picking buffers last so they deterministically win
        // equal-depth overlaps with traces. Keep them separate while walking layers because the
        // visible board geometry itself must retain its normal physical back-to-front ordering.
        var priorityPickingPositions: [Position3] = []
        var priorityPickingIdentifiers: [UInt32] = []
        var identifierByTarget: [PickTarget: UInt32] = [:]
        var targetsByIdentifier: [UInt32: PickTarget] = [:]
        var positionsByTarget: [PickTarget: [Position3]] = [:]
        var nextPickingIdentifier: UInt32 = 1
        let invalidReferences = activity?.invalidComponentReferences ?? []
        var maskPositions: [Position3] = []
        var maskColors: [SIMD4<Float>] = []
        var maskNormals: [Position3] = []
        var maskMuteFlags: [Float] = []

        // Submit in physical Z order rather than array order (silkscreen is appended after copper,
        // so a plain reversed array would still put F.Silkscreen in the wrong place): back/bottom
        // first, front/top last. Keep the original index for visibility and color lookup.
        let backToFrontLayerIndices = preview.layers.indices.sorted {
            preview.layers[$0].z < preview.layers[$1].z
        }
        for index in backToFrontLayerIndices {
            let layer = preview.layers[index]
            // Hidden layers still seed the hull distance field: the slicing hull is one shared
            // board-wide region built from every layer's copper, whichever layers are shown.
            let isLayerHidden = hiddenLayerIndices.contains(index)
            let layerColor = Self.simdColor(for: layer, index: index, total: preview.layers.count)
            let z = Float(layer.z)
            let isSolderMaskLayer = layer.name == "F.Mask" || layer.name == "B.Mask"
            for triangle in layer.triangles {
                if isLayerHidden {
                    if let netName = triangle.netName, let padding = activity?.hullPaddingByNet[netName] {
                        regionSeedPositionsByPadding[padding, default: []].append(contentsOf: [
                            Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                            Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                            Position3(Float(triangle.c.x), Float(triangle.c.y), z)])
                    }
                    continue
                }
                // Dynamically loaded mask lives in preview.layers so the list exactly mirrors
                // KiCad, but it must still use the dedicated mask pass. Treating its 0.45 opacity
                // as an ordinary zone put it in zonePositionBuffer, where it blended over copper.
                if isSolderMaskLayer {
                    Self.appendLitTriangle(Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                                            Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                                            Position3(Float(triangle.c.x), Float(triangle.c.y), z),
                                            color: Self.solderMaskColor, muted: false,
                                            positions: &maskPositions, colors: &maskColors,
                                            normals: &maskNormals, muteFlags: &maskMuteFlags)
                    continue
                }
                // Alpha 0 is the "no override" sentinel (see EMSGeometryTriangle.color's own doc
                // comment) -- real copper is always fully opaque, so a real per-triangle color
                // (the whole-board preview's own net coloring) never collides with it.
                let color = triangle.color.w > 0
                    ? SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y), Float(triangle.color.z),
                                   Float(triangle.color.w))
                    : layerColor
                // Left unmuted here and combined (once, via OR -- see boardMuteFlagBuffer's own doc
                // comment) with the region-highlight's own per-pixel "outside the hull" test in
                // geometry_pbr_fragment, rather than baking mutedSimulationColor in on the CPU as
                // this used to.
                var isMuted = false
                var isHullSeedCopper = false
                var isSimulatedCopper = false
                var hullPaddingMicrometers: Double?
                if let netName = triangle.netName {
                    let netIncluded = activity?.configurationIncludedNets.contains(netName) == true
                        || activity?.fullySaturatedNets.contains(netName) == true
                    isMuted = activity?.hasSelectedSimulation == true && !netIncluded
                    // Every full simulation net grows the real slicing hull. Geometry-only and
                    // ground nets remain context and must not seed this distance field.
                    hullPaddingMicrometers = activity?.hullPaddingByNet[netName]
                    isHullSeedCopper = hullPaddingMicrometers != nil
                    isSimulatedCopper = activity?.includedNets.contains(netName) == true
                }
                if activity?.hasSelectedSimulation == true,
                   layer.name == "F.Silkscreen" || layer.name == "B.Silkscreen" {
                    let belongsToInvolvedComponent = triangle.footprintReference.map {
                        activity?.involvedComponentReferences.contains($0) == true
                    } ?? false
                    if !belongsToInvolvedComponent {
                        isMuted = true
                    }
                }
                let a = Position3(Float(triangle.a.x), Float(triangle.a.y), z)
                let b = Position3(Float(triangle.b.x), Float(triangle.b.y), z)
                let c = Position3(Float(triangle.c.x), Float(triangle.c.y), z)
                let pickTarget: PickTarget?
                let geometryTarget: PickTarget?
                switch triangle.kind {
                case .pin:
                    if let reference = triangle.footprintReference {
                        let pinTarget = PickTarget.pin(reference: reference, number: triangle.padNumber ?? "",
                                                       net: triangle.netName)
                        geometryTarget = pinTarget
                        // Faulty passives are selected as one component from either terminal;
                        // valid pads retain their existing pin-selection behavior.
                        pickTarget = invalidReferences.contains(reference) ? .component(reference) : pinTarget
                    } else {
                        pickTarget = nil
                        geometryTarget = nil
                    }
                case .trace:
                    pickTarget = triangle.netName.map(PickTarget.net)
                    geometryTarget = pickTarget
                case .zone:
                    pickTarget = .zone(triangle.netName)
                    geometryTarget = pickTarget
                default:
                    pickTarget = nil
                    geometryTarget = nil
                }
                let pickingIdentifier: UInt32
                if let pickTarget {
                    if let existing = identifierByTarget[pickTarget] {
                        pickingIdentifier = existing
                    } else {
                        pickingIdentifier = nextPickingIdentifier
                        nextPickingIdentifier += 1
                        identifierByTarget[pickTarget] = pickingIdentifier
                        targetsByIdentifier[pickingIdentifier] = pickTarget
                    }
                } else {
                    pickingIdentifier = 0
                }
                let hasPickPriority = pickTarget?.hasPickPriority == true
                if triangle.opacity < 1 {
                    var translucentColor = color
                    translucentColor.w = Float(triangle.opacity)
                    // One simulation unit (0.1 micron) behind this layer's opaque copper: enough
                    // to make tracks/pads win the depth test without visibly separating the pour.
                    let zoneZ = z - 1
                    let pickA = Position3(a.x, a.y, zoneZ)
                    let pickB = Position3(b.x, b.y, zoneZ)
                    let pickC = Position3(c.x, c.y, zoneZ)
                    Self.appendLitTriangle(pickA, pickB, pickC, color: translucentColor, muted: isMuted,
                                            forceUnmutedByRegion: isSimulatedCopper,
                                            positions: &zonePositions, colors: &zoneColors, normals: &zoneNormals,
                                            muteFlags: &zoneMuteFlags)
                    if hasPickPriority {
                        priorityPickingPositions.append(contentsOf: [pickA, pickB, pickC])
                        priorityPickingIdentifiers.append(
                            contentsOf: [pickingIdentifier, pickingIdentifier, pickingIdentifier])
                    } else {
                        pickingPositions.append(contentsOf: [pickA, pickB, pickC])
                        pickingIdentifiers.append(
                            contentsOf: [pickingIdentifier, pickingIdentifier, pickingIdentifier])
                    }
                    if let geometryTarget {
                        positionsByTarget[geometryTarget, default: []].append(contentsOf: [pickA, pickB, pickC])
                    }
                    if let pickTarget, pickTarget != geometryTarget {
                        positionsByTarget[pickTarget, default: []].append(contentsOf: [pickA, pickB, pickC])
                    }
                    if isHullSeedCopper {
                        regionSeedPositionsByPadding[hullPaddingMicrometers!, default: []]
                            .append(contentsOf: [pickA, pickB, pickC])
                    }
                } else {
                    Self.appendLitTriangle(a, b, c, color: color, muted: isMuted,
                                            forceUnmutedByRegion: isSimulatedCopper,
                                            positions: &positions, colors: &colors, normals: &normals,
                                            muteFlags: &muteFlags)
                    if hasPickPriority {
                        priorityPickingPositions.append(contentsOf: [a, b, c])
                        priorityPickingIdentifiers.append(
                            contentsOf: [pickingIdentifier, pickingIdentifier, pickingIdentifier])
                    } else {
                        pickingPositions.append(contentsOf: [a, b, c])
                        pickingIdentifiers.append(
                            contentsOf: [pickingIdentifier, pickingIdentifier, pickingIdentifier])
                    }
                    if let geometryTarget {
                        positionsByTarget[geometryTarget, default: []].append(contentsOf: [a, b, c])
                    }
                    if let pickTarget, pickTarget != geometryTarget {
                        positionsByTarget[pickTarget, default: []].append(contentsOf: [a, b, c])
                    }
                    if isHullSeedCopper {
                        regionSeedPositionsByPadding[hullPaddingMicrometers!, default: []]
                            .append(contentsOf: [a, b, c])
                    }
                }
            }
        }
        zoneVertexCount = zonePositions.count
        zonePositionBuffer = zonePositions.isEmpty ? nil : device.makeBuffer(
            bytes: zonePositions, length: MemoryLayout<Position3>.stride * zonePositions.count)
        zoneColorBuffer = zoneColors.isEmpty ? nil : device.makeBuffer(
            bytes: zoneColors, length: MemoryLayout<SIMD4<Float>>.stride * zoneColors.count)
        zoneNormalBuffer = zoneNormals.isEmpty ? nil : device.makeBuffer(
            bytes: zoneNormals, length: MemoryLayout<Position3>.stride * zoneNormals.count)
        zoneMuteFlagBuffer = zoneMuteFlags.isEmpty ? nil : device.makeBuffer(
            bytes: zoneMuteFlags, length: MemoryLayout<Float>.stride * zoneMuteFlags.count)

        // Solder mask, if this board's stackup has one on that side (see EMSGeometryPreview.
        // topSolderMask/bottomSolderMask's own doc comment) -- built into its own separate buffer,
        // drawn in draw(in:)'s own translucent pass after everything above, rather than appended
        // into this opaque positions/colors pair like every other element in this loop.
        let maskLayers = [
            hideTopSolderMask ? nil : preview.topSolderMask,
            hideBottomSolderMask ? nil : preview.bottomSolderMask,
        ].compactMap { $0 }
        for maskLayer in maskLayers {
            let z = Float(maskLayer.z)
            for triangle in maskLayer.triangles {
                Self.appendLitTriangle(Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                                        Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                                        Position3(Float(triangle.c.x), Float(triangle.c.y), z),
                                        color: Self.solderMaskColor, muted: false, positions: &maskPositions,
                                        colors: &maskColors, normals: &maskNormals, muteFlags: &maskMuteFlags)
            }
        }
        maskVertexCount = maskPositions.count
        maskPositionBuffer = maskPositions.isEmpty ? nil : device.makeBuffer(
            bytes: maskPositions, length: MemoryLayout<Position3>.stride * maskPositions.count)
        maskColorBuffer = maskColors.isEmpty ? nil : device.makeBuffer(
            bytes: maskColors, length: MemoryLayout<SIMD4<Float>>.stride * maskColors.count)
        maskNormalBuffer = maskNormals.isEmpty ? nil : device.makeBuffer(
            bytes: maskNormals, length: MemoryLayout<Position3>.stride * maskNormals.count)
        maskMuteFlagBuffer = maskMuteFlags.isEmpty ? nil : device.makeBuffer(
            bytes: maskMuteFlags, length: MemoryLayout<Float>.stride * maskMuteFlags.count)

        // Real 3D via geometry (open barrel tube + per-layer annular rings -- see
        // EMSGeometryPreview.viaMeshTriangles' own doc comment) -- replaces the old flat, single-Z
        // concentric-capsule marker this used to draw here: that read fine from the old fixed
        // top-down 2D view, but from any angle a real 3D camera can now reach, three flat discs
        // floating at one Z (and copper layers with no hole cut for them to sit in) just look wrong.
        // Each vertex keeps its own real Z, same as componentMeshTriangles below, not a shared flat
        // markerZ.
        for triangle in preview.viaMeshTriangles {
            let color = SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y), Float(triangle.color.z),
                                      Float(triangle.color.w))
            var isMuted = false
            var isHullSeedCopper = false
            var isSimulatedCopper = false
            var hullPaddingMicrometers: Double?
            if let netName = triangle.netName {
                let netIncluded = activity?.configurationIncludedNets.contains(netName) == true
                    || activity?.fullySaturatedNets.contains(netName) == true
                isMuted = activity?.hasSelectedSimulation == true && !netIncluded
                // Match layer copper above: every full simulation net seeds the slicing boundary.
                hullPaddingMicrometers = activity?.hullPaddingByNet[netName]
                isHullSeedCopper = hullPaddingMicrometers != nil
                isSimulatedCopper = activity?.includedNets.contains(netName) == true
            }
            let a = Position3(Float(triangle.a.x), Float(triangle.a.y), Float(triangle.a.z))
            let b = Position3(Float(triangle.b.x), Float(triangle.b.y), Float(triangle.b.z))
            let c = Position3(Float(triangle.c.x), Float(triangle.c.y), Float(triangle.c.z))
            Self.appendLitTriangle(a, b, c, color: color, muted: isMuted,
                                    forceUnmutedByRegion: isSimulatedCopper,
                                    positions: &positions, colors: &colors, normals: &normals,
                                    muteFlags: &muteFlags)
            if isHullSeedCopper {
                regionSeedPositionsByPadding[hullPaddingMicrometers!, default: []]
                    .append(contentsOf: [a, b, c])
            }
            guard let netName = triangle.netName else { continue }
            let pickTarget = PickTarget.net(netName)
            let pickingIdentifier: UInt32
            if let existing = identifierByTarget[pickTarget] {
                pickingIdentifier = existing
            } else {
                pickingIdentifier = nextPickingIdentifier
                nextPickingIdentifier += 1
                identifierByTarget[pickTarget] = pickingIdentifier
                targetsByIdentifier[pickingIdentifier] = pickTarget
            }
            pickingPositions.append(contentsOf: [a, b, c])
            pickingIdentifiers.append(contentsOf: [pickingIdentifier, pickingIdentifier, pickingIdentifier])
            positionsByTarget[pickTarget, default: []].append(contentsOf: [a, b, c])
        }

        // Every trace/hull intersection remains pickable even before it has a port role, but an
        // inactive candidate is deliberately invisible. Configured roles use the same concentric
        // blue/yellow/red language as pin ports.
        for spot in activity?.hullCutPortSpots ?? [] {
            let target = PickTarget.hullCutPort(identifier: spot.identifier, net: spot.netName)
            let identifier: UInt32
            if let existing = identifierByTarget[target] {
                identifier = existing
            } else {
                identifier = nextPickingIdentifier
                nextPickingIdentifier += 1
                identifierByTarget[target] = identifier
                targetsByIdentifier[identifier] = target
            }
            // Only the pick disc lives here; its visible role markers are drawn by
            // rebuildMarkerBuffers(), so toggling a role doesn't rebuild the board.
            var discPositions: [Position3] = []
            var discColors: [SIMD4<Float>] = []
            var discNormals: [Position3] = []
            var discMuteFlags: [Float] = []
            Self.appendDisc(center: spot.position, radius: Self.absorbingPinMarkerRadius, z: markerZ,
                            color: Self.absorbingPinColor, positions: &discPositions, colors: &discColors,
                            normals: &discNormals, muteFlags: &discMuteFlags)
            priorityPickingPositions.append(contentsOf: discPositions)
            priorityPickingIdentifiers.append(contentsOf: repeatElement(identifier, count: discPositions.count))
            positionsByTarget[target, default: []].append(contentsOf: discPositions)
        }

        // The controller has already restricted passive candidates by net membership. Apply the
        // remaining spatial rule here, where real pad geometry and the main-excitation hull seeds
        // are both available: at least one pad must lie in the cut area. SimulationNet copper is
        // always retained at its exact footprint; other eligible nets must fall within the padded
        // main-excitation region.
        let eligiblePassiveReferences = Set((activity?.passiveBridges ?? []).map(\.reference))
        var passiveReferencesInsideCut = Set<String>()
        if let activity {
            func pointSegmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
                let ab = b - a
                let lengthSquared = simd_length_squared(ab)
                let t = lengthSquared > 0 ? max(0, min(1, simd_dot(p - a, ab) / lengthSquared)) : 0
                return simd_distance(p, a + t * ab)
            }
            func pointIsInsideCut(_ point: SIMD2<Float>) -> Bool {
                for (paddingMicrometers, positions) in regionSeedPositionsByPadding {
                    let padding = Float(paddingMicrometers * Self.simUnitsPerMicrometer)
                    var index = 0
                    while index + 2 < positions.count {
                        let a = SIMD2<Float>(positions[index].x, positions[index].y)
                        let b = SIMD2<Float>(positions[index + 1].x, positions[index + 1].y)
                        let c = SIMD2<Float>(positions[index + 2].x, positions[index + 2].y)
                        let ab = b - a
                        let bc = c - b
                        let ca = a - c
                        let ap = point - a
                        let bp = point - b
                        let cp = point - c
                        let crosses = [ab.x * ap.y - ab.y * ap.x,
                                       bc.x * bp.y - bc.y * bp.x,
                                       ca.x * cp.y - ca.y * cp.x]
                        if crosses.allSatisfy({ $0 >= 0 }) || crosses.allSatisfy({ $0 <= 0 }) {
                            return true
                        }
                        let distance = min(pointSegmentDistance(point, a, b),
                                           min(pointSegmentDistance(point, b, c),
                                               pointSegmentDistance(point, c, a)))
                        if distance <= padding { return true }
                        index += 3
                    }
                }
                return false
            }
            func pinInsideCut(reference: String, pad: String, net: String) -> Bool {
                if activity.includedNets.contains(net) { return true }
                guard let pinPositions = Self.positions(reference: reference, padNumber: pad,
                                                        in: positionsByTarget),
                      let center = Self.centroid(of: pinPositions)
                else { return false }
                return pointIsInsideCut(SIMD2<Float>(center.x, center.y))
            }
            for bridge in activity.passiveBridges
                where pinInsideCut(reference: bridge.reference, pad: bridge.firstPad, net: bridge.firstNet)
                    || pinInsideCut(reference: bridge.reference, pad: bridge.secondPad, net: bridge.secondNet) {
                passiveReferencesInsideCut.insert(bridge.reference)
            }
        }

        // Real 3D models of every included footprint (see EMSGeometryComponentTriangle's own doc
        // comment) -- unlike every other marker here, each vertex keeps its own real Z from the
        // mesh (a component has genuine 3D shape), not a shared flat markerZ. Color is the model's
        // own real STEP color (see EMSGeometryComponentTriangle.color's own doc comment), not the
        // fixed accent color used everywhere else in this view -- STL (which carries no color data)
        // is no longer what these come from.
        if !hideComponents {
            for triangle in preview.componentMeshTriangles {
                let originalColor = SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y),
                                                  Float(triangle.color.z), Float(triangle.color.w))
                let isInvalid = triangle.footprintReference.map(invalidReferences.contains) ?? false
                let color = isInvalid ? Self.invalidComponentColor(originalColor) : originalColor
                let isMuted = !isInvalid && activity?.hasSelectedSimulation == true
                    && (triangle.footprintReference.map { reference in
                        if eligiblePassiveReferences.contains(reference) {
                            return !passiveReferencesInsideCut.contains(reference)
                        }
                        return activity?.involvedComponentReferences.contains(reference) != true
                    } ?? false)
                let a = Position3(Float(triangle.a.x), Float(triangle.a.y), Float(triangle.a.z))
                let b = Position3(Float(triangle.b.x), Float(triangle.b.y), Float(triangle.b.z))
                let c = Position3(Float(triangle.c.x), Float(triangle.c.y), Float(triangle.c.z))
                Self.appendLitTriangle(a, b, c,
                                        color: color, muted: isMuted, forceUnmutedByRegion: isInvalid,
                                        positions: &positions, colors: &colors,
                                        normals: &normals, muteFlags: &muteFlags)
                if isInvalid, let reference = triangle.footprintReference {
                    let pickTarget = PickTarget.component(reference)
                    let pickingIdentifier: UInt32
                    if let existing = identifierByTarget[pickTarget] {
                        pickingIdentifier = existing
                    } else {
                        pickingIdentifier = nextPickingIdentifier
                        nextPickingIdentifier += 1
                        identifierByTarget[pickTarget] = pickingIdentifier
                        targetsByIdentifier[pickingIdentifier] = pickTarget
                    }
                    priorityPickingPositions.append(contentsOf: [a, b, c])
                    priorityPickingIdentifiers.append(contentsOf: repeatElement(pickingIdentifier, count: 3))
                    positionsByTarget[pickTarget, default: []].append(contentsOf: [a, b, c])
                }
            }
        }

        boardVertexCount = positions.count
        boardPositionBuffer = positions.isEmpty ? nil : device.makeBuffer(
            bytes: positions, length: MemoryLayout<Position3>.stride * positions.count)
        boardColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count)
        boardNormalBuffer = normals.isEmpty ? nil : device.makeBuffer(
            bytes: normals, length: MemoryLayout<Position3>.stride * normals.count)
        boardMuteFlagBuffer = muteFlags.isEmpty ? nil : device.makeBuffer(
            bytes: muteFlags, length: MemoryLayout<Float>.stride * muteFlags.count)

        regionSeedGroups = regionSeedPositionsByPadding.compactMap { padding, positions in
            guard !positions.isEmpty, let buffer = device.makeBuffer(
                bytes: positions, length: MemoryLayout<Position3>.stride * positions.count)
            else { return nil }
            return RegionSeedGroup(paddingMicrometers: padding, positionBuffer: buffer,
                                   vertexCount: positions.count)
        }.sorted { $0.paddingMicrometers < $1.paddingMicrometers }

        // Record the split before appending pins. pick(at:) submits the two ranges separately so
        // the pin range can receive its small, explicit depth bias.
        pickingPriorityVertexStart = pickingPositions.count
        pickingPositions.append(contentsOf: priorityPickingPositions)
        pickingIdentifiers.append(contentsOf: priorityPickingIdentifiers)
        pickingVertexCount = pickingPositions.count
        pickingPositionBuffer = pickingPositions.isEmpty ? nil : device.makeBuffer(
            bytes: pickingPositions, length: MemoryLayout<Position3>.stride * pickingPositions.count)
        pickingIdentifierBuffer = pickingIdentifiers.isEmpty ? nil : device.makeBuffer(
            bytes: pickingIdentifiers, length: MemoryLayout<UInt32>.stride * pickingIdentifiers.count)
        pickTargetsByIdentifier = targetsByIdentifier
        pickPositionsByTarget = positionsByTarget
        rebuildHighlightBuffer()
        rebuildActivityBuffers()

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

        rebuildMarkerBuffers()
    }

    /// Port/probe/excitation dots, planned stitching vias and rejected-via crosses. Kept apart from
    /// rebuildBoardBuffers() so a port-role edit in Setup (absorbing, probed, excited, impedance)
    /// only redraws these few hundred vertices instead of re-tessellating the whole board. Reads
    /// pad positions from pickPositionsByTarget, so it must run after the board buffers are built.
    private func rebuildMarkerBuffers() {
        guard let device, let preview else {
            markerVertexCount = 0
            crossVertexCount = 0
            return
        }
        let layerZValues = preview.layers.map { Float($0.z) }
        let topZ = layerZValues.max() ?? 0
        let bottomZ = layerZValues.min() ?? 0
        let markerZ = topZ + max(topZ - bottomZ, 1) * 0.01
        // Stacked marker colours are separate coplanar discs. Give each foreground colour a small
        // physical depth step as well as a smaller radius; draw order alone would otherwise leave
        // their shared interiors vulnerable to z-fighting.
        let markerDepthStep = max(topZ - bottomZ, 1) * 0.001

        var positions: [Position3] = []
        var colors: [SIMD4<Float>] = []
        var normals: [Position3] = []
        var muteFlags: [Float] = []

        // Setup shows the exact accepted candidates from a dry run of board slicing as flat gold
        // dots. The real Geometry view continues to show its completed vias as full 3D meshes.
        let plannedViaRadius = max((activity?.plannedStitchingViaDiameter ?? 0) / 2, 1)
        for point in activity?.plannedStitchingViaPositions ?? [] {
            Self.appendDisc(center: point, radius: plannedViaRadius, z: markerZ,
                            color: Self.plannedViaColor, positions: &positions, colors: &colors,
                            normals: &normals, muteFlags: &muteFlags)
        }

        for spot in activity?.hullCutPortSpots ?? [] {
            if spot.absorbing {
                Self.appendDisc(center: spot.position, radius: Self.absorbingPinMarkerRadius, z: markerZ,
                                color: Self.absorbingPinColor, positions: &positions, colors: &colors,
                                normals: &normals, muteFlags: &muteFlags)
            }
            if spot.probed {
                Self.appendDisc(center: spot.position, radius: Self.probedPinMarkerRadius,
                                z: markerZ + markerDepthStep, color: Self.probedPinColor,
                                positions: &positions, colors: &colors, normals: &normals,
                                muteFlags: &muteFlags)
            }
            if spot.excited {
                Self.appendDisc(center: spot.position, radius: Self.excitedPinMarkerRadius,
                                z: markerZ + 2 * markerDepthStep, color: Self.excitedPinColor,
                                positions: &positions, colors: &colors, normals: &normals,
                                muteFlags: &muteFlags)
            }
        }

        for port in preview.ports {
            let radius = max(CGFloat(port.width) / 2, 1)
            Self.appendDisc(center: port.position, radius: radius, z: markerZ,
                             color: port.absorbSignal ? Self.portColor : Self.probeColor,
                             positions: &positions, colors: &colors, normals: &normals, muteFlags: &muteFlags)
        }

        // Absorbing pins form the large blue backing/border for any yellow probe or red excitation
        // marker subsequently placed on the same pin.
        for pin in activity?.absorbingPins ?? [] {
            guard let pinPositions = Self.positions(reference: pin.reference, padNumber: pin.padNumber,
                                                      in: pickPositionsByTarget),
                  let centroid = Self.centroid(of: pinPositions)
            else { continue }
            Self.appendDisc(center: CGPoint(x: CGFloat(centroid.x), y: CGFloat(centroid.y)),
                             radius: Self.absorbingPinMarkerRadius, z: markerZ,
                             color: Self.absorbingPinColor,
                             positions: &positions, colors: &colors, normals: &normals, muteFlags: &muteFlags)
        }

        // Probed pins get a smaller yellow centre, slightly forward of the blue absorbing disc.
        for pin in activity?.probedPins ?? [] {
            guard let pinPositions = Self.positions(reference: pin.reference, padNumber: pin.padNumber,
                                                      in: pickPositionsByTarget),
                  let centroid = Self.centroid(of: pinPositions)
            else { continue }
            Self.appendDisc(center: CGPoint(x: CGFloat(centroid.x), y: CGFloat(centroid.y)),
                             radius: Self.probedPinMarkerRadius, z: markerZ + markerDepthStep,
                             color: Self.probedPinColor,
                             positions: &positions, colors: &colors, normals: &normals, muteFlags: &muteFlags)
        }

        // Excited pins get their own bright marker, distinct from every port/probe color above --
        // and sit one more depth step forward so red remains unambiguous if a pin is also probed.
        // See BoardActivityHighlight.ExcitedPin's own doc comment. Pad positions come from the
        // board's already-built pick geometry.
        for pin in activity?.excitedPins ?? [] {
            guard let pinPositions = Self.positions(reference: pin.reference, padNumber: pin.padNumber,
                                                      in: pickPositionsByTarget),
                  let centroid = Self.centroid(of: pinPositions)
            else { continue }
            Self.appendDisc(center: CGPoint(x: CGFloat(centroid.x), y: CGFloat(centroid.y)),
                             radius: Self.excitedPinMarkerRadius, z: markerZ + 2 * markerDepthStep,
                             color: Self.excitedPinColor,
                             positions: &positions, colors: &colors, normals: &normals, muteFlags: &muteFlags)
        }

        markerVertexCount = positions.count
        markerPositionBuffer = positions.isEmpty ? nil : device.makeBuffer(
            bytes: positions, length: MemoryLayout<Position3>.stride * positions.count)
        markerColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count)
        markerNormalBuffer = normals.isEmpty ? nil : device.makeBuffer(
            bytes: normals, length: MemoryLayout<Position3>.stride * normals.count)
        markerMuteFlagBuffer = muteFlags.isEmpty ? nil : device.makeBuffer(
            bytes: muteFlags, length: MemoryLayout<Float>.stride * muteFlags.count)

        // Setup's rejected candidates use the planned annular-ring diameter. Completed Geometry
        // previews instead size from an existing via, with a fixed fallback only when neither is
        // available, so a cross always reads as roughly "the via that didn't get placed here."
        let plannedCrossHalfLength = (activity?.plannedStitchingViaDiameter ?? 0) / 2
        let crossHalfLength = plannedCrossHalfLength > 0 ? plannedCrossHalfLength
            : (preview.vias.first.map { CGFloat($0.diameter) / 2 } ?? Self.failedViaAttemptFallbackHalfLength)
        var crossPositions: [Position3] = []
        var crossColors: [SIMD4<Float>] = []
        let rejectedPositions = preview.failedViaAttempts.map(\.pointValue)
            + (activity?.rejectedStitchingViaPositions ?? [])
        for point in rejectedPositions {
            Self.appendCross(center: point, halfLength: crossHalfLength, z: markerZ,
                              color: Self.failedViaAttemptColor, positions: &crossPositions, colors: &crossColors)
        }
        crossVertexCount = crossPositions.count
        crossPositionBuffer = crossPositions.isEmpty ? nil : device.makeBuffer(
            bytes: crossPositions, length: MemoryLayout<Position3>.stride * crossPositions.count)
        crossColorBuffer = crossColors.isEmpty ? nil : device.makeBuffer(
            bytes: crossColors, length: MemoryLayout<SIMD4<Float>>.stride * crossColors.count)
    }

    private func rebuildHighlightBuffer() {
        guard let device, let selectedTarget else {
            highlightPositionBuffer = nil
            highlightColorBuffer = nil
            highlightVertexCount = 0
            return
        }

        var positions: [Position3] = []
        switch selectedTarget {
        case .pin, .component, .hullCutPort:
            positions = pickPositionsByTarget[selectedTarget] ?? []
        case let .net(selectedNet):
            for (target, targetPositions) in pickPositionsByTarget where target.netName == selectedNet {
                positions.append(contentsOf: targetPositions)
            }
        case .zone:
            break
        }
        let colors = Array(repeating: SIMD4<Float>(1, 1, 1, 0.42), count: positions.count)
        highlightVertexCount = positions.count
        highlightPositionBuffer = positions.isEmpty ? nil : device.makeBuffer(
            bytes: positions, length: MemoryLayout<Position3>.stride * positions.count)
        highlightColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count)
    }

    /// One endpoint in a trace component's internal centerline graph. This is deliberately scoped
    /// by layer as well as net: tracks crossing at the same XY on different layers are not
    /// electrically connected unless a via landmark joins their two trace components.
    private struct ActivityGraphNode {
        let net: String
        let layer: String
        let x: Float, y: Float, z: Float
    }

    /// One real routed track segment in a trace component's internal centerline graph.
    private struct ActivityGraphSegment {
        let a: Int
        let b: Int
        let layer: String
        let ax: Float, ay: Float, bx: Float, by: Float, z: Float
        let length: Float
    }

    private struct ActivityGraphAttachment {
        let index: Int
        let weight: Float
    }

    /// Public graph nodes are only physical electrical landmarks. Trace components are converted
    /// into weighted edges between these nodes; raw track endpoints remain an implementation detail
    /// used to measure those edge lengths and to produce the per-vertex animation phase.
    private enum ActivityLandmarkKey: Hashable {
        case pin(reference: String, number: String)
        case via(Int)
    }

    private struct ActivityLandmark {
        let key: ActivityLandmarkKey
        let net: String
        let x: Float, y: Float
        var attachments: [ActivityGraphAttachment]
    }

    /// Binary min-heap for the single multi-source Dijkstra below.
    private struct ActivityPriorityQueue {
        private var heap: [(node: Int, distance: Float)] = []

        var isEmpty: Bool { heap.isEmpty }

        mutating func push(node: Int, distance: Float) {
            heap.append((node, distance))
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard heap[child].distance < heap[parent].distance else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        mutating func popMin() -> (node: Int, distance: Float)? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let result = heap[0]
            heap[0] = heap.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                let child = right < heap.count && heap[right].distance < heap[left].distance ? right : left
                guard heap[child].distance < heap[parent].distance else { break }
                heap.swapAt(child, parent)
                parent = child
            }
            return result
        }
    }

    /// Builds the translucent flash/ripple overlay (activityPositionBuffer/activityColorBuffer/
    /// activityDistanceBuffer) for every net in activity.includedNets, using this view's own
    /// already-built pickPositionsByTarget for real copper positions (the same geometry the
    /// click-selection highlight above reads from) -- called whenever `activity` changes, or
    /// whenever the board's own geometry does (rebuildBoardBuffers() calls this too, since new
    /// preview data means pickPositionsByTarget itself just got rebuilt).
    ///
    /// The externally meaningful nodes are pins and vias. Raw KiCad track endpoints and junctions
    /// remain hidden topology nodes, allowing one graph construction to represent a trace component
    /// touching any number of landmarks without running an all-pairs search to materialize a
    /// complete landmark graph. Vias attach one landmark to centerlines on multiple layers;
    /// coincident tracks on different layers never connect without one. Two-pin passives add the
    /// only cross-net edges.
    ///
    /// One multi-source Dijkstra rooted at the excitation pins produces the shortest-path tree. (A
    /// minimum spanning tree would minimize total tree length, not each node's route back to the
    /// excitation, and can therefore point an edge the wrong way.) A rendered raw segment uses the
    /// lower-distance endpoint for its *entire* interpolation; it never takes min(distance from A,
    /// distance from B) per vertex, which creates a midpoint where the gradient reverses and was the
    /// source of the backwards-moving pulses. Unreachable fragments keep the -1 sentinel and all
    /// flash in lockstep in board_activity_fragment.
    private func rebuildActivityBuffers() {
        guard let device, let activity, !activity.includedNets.isEmpty else {
            activityPositionBuffer = nil
            activityColorBuffer = nil
            activityDistanceBuffer = nil
            activityVertexCount = 0
            return
        }

        // Every net name this search could possibly touch -- every included net, every excited
        // pin's own net, and every passive bridge's own two nets, since current can cross an
        // unincluded net's own real copper on its way to one that is (e.g. a chain of two caps
        // through an intermediate, not-rendered net).
        var relevantNets = activity.includedNets
        for pin in activity.excitedPins { relevantNets.insert(pin.netName) }
        for bridge in activity.passiveBridges {
            relevantNets.insert(bridge.firstNet)
            relevantNets.insert(bridge.secondNet)
        }

        struct NodeKey: Hashable { let net: String, layer: String, x: Int32, y: Int32 }
        // Position queries for tracks/vias/pads come from different libkicad calls -- a
        // x10-scale-then-round tolerance merges genuinely-coincident points (a via sitting exactly
        // at a segment's own endpoint) without ever conflating two distinct nearby ones.
        func quantize(_ x: Float, _ y: Float) -> (Int32, Int32) {
            let scale: Float = 10
            return (Int32((x * scale).rounded()), Int32((y * scale).rounded()))
        }
        var indexOfNode: [NodeKey: Int] = [:]
        var nodes: [ActivityGraphNode] = []
        var neighbors: [[(index: Int, weight: Float)]] = []
        func ensureCapacity() {
            while neighbors.count < nodes.count { neighbors.append([]) }
        }
        let layerZ = Dictionary(uniqueKeysWithValues: (preview?.layers ?? []).map { ($0.name, Float($0.z)) })
        func nodeIndex(net: String, layer: String, x: Float, y: Float) -> Int {
            let (qx, qy) = quantize(x, y)
            let key = NodeKey(net: net, layer: layer, x: qx, y: qy)
            if let existing = indexOfNode[key] { return existing }
            let newIndex = nodes.count
            indexOfNode[key] = newIndex
            nodes.append(ActivityGraphNode(net: net, layer: layer, x: x, y: y, z: layerZ[layer] ?? 0))
            return newIndex
        }
        func addEdge(_ a: Int, _ b: Int, weight: Float) {
            ensureCapacity()
            guard a != b else { return }
            neighbors[a].append((b, weight))
            neighbors[b].append((a, weight))
        }

        // Internal centerline graph, scoped by net *and* layer.
        var segmentsByNet: [String: [ActivityGraphSegment]] = [:]
        for segment in preview?.trackSegments ?? [] where relevantNets.contains(segment.netName) {
            let ax = Float(segment.start.x), ay = Float(segment.start.y)
            let bx = Float(segment.end.x), by = Float(segment.end.y)
            let a = nodeIndex(net: segment.netName, layer: segment.layerName, x: ax, y: ay)
            let b = nodeIndex(net: segment.netName, layer: segment.layerName, x: bx, y: by)
            let length = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot()
            addEdge(a, b, weight: length)
            segmentsByNet[segment.netName, default: []].append(
                ActivityGraphSegment(a: a, b: b, layer: segment.layerName,
                                     ax: ax, ay: ay, bx: bx, by: by,
                                     z: layerZ[segment.layerName] ?? 0, length: length))
        }
        ensureCapacity()

        /// Returns the closest centreline position as a fraction of this segment and the XY
        /// distance to it. Shared by topology attachment and render-phase assignment so the two
        /// cannot disagree about which physical part of a track a point touches.
        func projection(ofX x: Float, y: Float, onto segment: ActivityGraphSegment)
            -> (t: Float, distance: Float) {
            let abx = segment.bx - segment.ax, aby = segment.by - segment.ay
            let lengthSquared = abx * abx + aby * aby
            let t: Float = lengthSquared > 0
                ? max(0, min(1, ((x - segment.ax) * abx + (y - segment.ay) * aby) / lengthSquared))
                : 0
            let dx = x - (segment.ax + t * abx)
            let dy = y - (segment.ay + t * aby)
            return (t, (dx * dx + dy * dy).squareRoot())
        }

        // KiCad normally terminates a branch exactly on another track, but does not necessarily
        // split that other track there. Make every same-net/same-layer endpoint lying on a
        // segment's interior a real graph junction. Without this, a visually continuous T branch
        // becomes two disconnected graph components and the pulse stops at an arbitrary point.
        // The spatial buckets keep this close to linear even after a curved route has been
        // flattened into many short centreline pieces by libkicad.
        struct NetLayerKey: Hashable { let net: String, layer: String }
        struct SegmentCellKey: Hashable { let netLayer: NetLayerKey, x: Int32, y: Int32 }
        let nodesByNetLayer = Dictionary(grouping: nodes.indices) {
            NetLayerKey(net: nodes[$0].net, layer: nodes[$0].layer)
        }
        let junctionTolerance: Float = 2
        let topologyCellSize: Float = 10_000 // 1 mm in simulation units
        func topologyCell(_ coordinate: Float) -> Int32 {
            Int32(floor(coordinate / topologyCellSize))
        }
        var segmentCells: [SegmentCellKey: [ActivityGraphSegment]] = [:]
        for (net, netSegments) in segmentsByNet {
            for segment in netSegments {
                let key = NetLayerKey(net: net, layer: segment.layer)
                let minX = topologyCell(min(segment.ax, segment.bx) - junctionTolerance)
                let maxX = topologyCell(max(segment.ax, segment.bx) + junctionTolerance)
                let minY = topologyCell(min(segment.ay, segment.by) - junctionTolerance)
                let maxY = topologyCell(max(segment.ay, segment.by) + junctionTolerance)
                for cellX in minX...maxX {
                    for cellY in minY...maxY {
                        segmentCells[SegmentCellKey(netLayer: key, x: cellX, y: cellY), default: []]
                            .append(segment)
                    }
                }
            }
        }
        for (key, nodeIndices) in nodesByNetLayer {
            for nodeIndex in nodeIndices {
                let node = nodes[nodeIndex]
                let cellKey = SegmentCellKey(netLayer: key, x: topologyCell(node.x), y: topologyCell(node.y))
                guard let layerSegments = segmentCells[cellKey] else { continue }
                for segment in layerSegments where nodeIndex != segment.a && nodeIndex != segment.b {
                    let projected = projection(ofX: node.x, y: node.y, onto: segment)
                    guard projected.distance <= junctionTolerance,
                          projected.t > 0, projected.t < 1 else { continue }
                    addEdge(nodeIndex, segment.a, weight: projected.t * segment.length)
                    addEdge(nodeIndex, segment.b, weight: (1 - projected.t) * segment.length)
                }
            }
        }

        // Collect pin copper independently of layer visibility. The default whole-board view hides
        // back/inner layers, but a hidden excitation pin must still seed topology that later reaches
        // a visible trace through a via.
        var pinGeometry: [ActivityLandmarkKey: (net: String, positions: [Position3])] = [:]
        for layer in preview?.layers ?? [] {
            let z = Float(layer.z)
            for triangle in layer.triangles where triangle.kind == .pin {
                guard let reference = triangle.footprintReference, let net = triangle.netName,
                      relevantNets.contains(net) else { continue }
                let key = ActivityLandmarkKey.pin(reference: reference, number: triangle.padNumber ?? "")
                let trianglePositions = [
                    Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                    Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                    Position3(Float(triangle.c.x), Float(triangle.c.y), z),
                ]
                if pinGeometry[key] == nil { pinGeometry[key] = (net, []) }
                pinGeometry[key]?.positions.append(contentsOf: trianglePositions)
            }
        }

        func point(_ node: ActivityGraphNode, liesIn triangles: [Position3]) -> Bool {
            let epsilon: Float = 1
            for index in stride(from: 0, to: triangles.count - 2, by: 3) {
                let a = triangles[index], b = triangles[index + 1], c = triangles[index + 2]
                guard abs(node.z - a.z) <= epsilon else { continue }
                let ab = (b.x - a.x) * (node.y - a.y) - (b.y - a.y) * (node.x - a.x)
                let bc = (c.x - b.x) * (node.y - b.y) - (c.y - b.y) * (node.x - b.x)
                let ca = (a.x - c.x) * (node.y - c.y) - (a.y - c.y) * (node.x - c.x)
                if (ab >= -epsilon && bc >= -epsilon && ca >= -epsilon)
                    || (ab <= epsilon && bc <= epsilon && ca <= epsilon) {
                    return true
                }
            }
            return false
        }

        var landmarks: [ActivityLandmark] = []
        var landmarkIndexByKey: [ActivityLandmarkKey: Int] = [:]
        func appendLandmark(key: ActivityLandmarkKey, net: String, position: Position3,
                            attachments: [ActivityGraphAttachment]) -> Int {
            if let existing = landmarkIndexByKey[key] {
                var bestByNode = Dictionary(uniqueKeysWithValues:
                    landmarks[existing].attachments.map { ($0.index, $0.weight) })
                for attachment in attachments {
                    bestByNode[attachment.index] = min(bestByNode[attachment.index] ?? .infinity,
                                                       attachment.weight)
                }
                landmarks[existing].attachments = bestByNode.map {
                    ActivityGraphAttachment(index: $0.key, weight: $0.value)
                }
                return existing
            }
            let index = landmarks.count
            landmarkIndexByKey[key] = index
            landmarks.append(ActivityLandmark(key: key, net: net, x: position.x, y: position.y,
                                               attachments: attachments))
            return index
        }

        let rawNodesByNet = Dictionary(grouping: nodes.indices, by: { nodes[$0].net })
        for (key, geometry) in pinGeometry {
            guard let centroid = Self.centroid(of: geometry.positions) else { continue }
            var attachmentNodes = (rawNodesByNet[geometry.net] ?? []).filter {
                point(nodes[$0], liesIn: geometry.positions)
            }
            // Degenerate/very unusual pad polygon: permit a nearby endpoint, but never snap a pin
            // across the board to an unrelated trace merely because it is the nearest one.
            if attachmentNodes.isEmpty, let nearest = (rawNodesByNet[geometry.net] ?? []).min(by: {
                Self.euclideanDistance(centroid, Position3(nodes[$0].x, nodes[$0].y, nodes[$0].z))
                    < Self.euclideanDistance(centroid, Position3(nodes[$1].x, nodes[$1].y, nodes[$1].z))
            }) {
                let radius = geometry.positions.map { Self.euclideanDistance(centroid, $0) }.max() ?? 0
                if Self.euclideanDistance(centroid,
                                           Position3(nodes[nearest].x, nodes[nearest].y, nodes[nearest].z))
                    <= radius + 100 {
                    attachmentNodes = [nearest]
                }
            }
            let attachments = attachmentNodes.map { ActivityGraphAttachment(index: $0, weight: 0) }
            _ = appendLandmark(key: key, net: geometry.net, position: centroid, attachments: attachments)
        }

        // One via landmark attaches to every layer's trace component that terminates at its XY.
        // Looking up by quantized XY is exact enough because both sources came from KiCad internal
        // coordinates before the same conversion to simulation units.
        var rawNodesByNetXY: [String: [String: [Int]]] = [:]
        for index in nodes.indices {
            let (x, y) = quantize(nodes[index].x, nodes[index].y)
            rawNodesByNetXY[nodes[index].net, default: [:]]["\(x):\(y)", default: []].append(index)
        }
        for (viaIndex, via) in (preview?.vias ?? []).enumerated() {
            guard let net = via.netName, relevantNets.contains(net) else { continue }
            // Use the annular-ring centre rather than one end of an oblong drill's centreline.
            // A track can terminate anywhere inside that copper, including on the interior of a
            // longer segment, so attach to both segment endpoints with their true along-track cost.
            let x = Float((via.ringPosition.x + via.ringPosition2.x) / 2)
            let y = Float((via.ringPosition.y + via.ringPosition2.y) / 2)
            let (qx, qy) = quantize(x, y)
            var bestAttachmentByNode: [Int: Float] = [:]
            for node in rawNodesByNetXY[net]?["\(qx):\(qy)"] ?? [] {
                bestAttachmentByNode[node] = 0
            }
            let ringRadius = Float(via.annularRingDiameter / 2)
            for segment in segmentsByNet[net] ?? [] {
                let projected = projection(ofX: x, y: y, onto: segment)
                guard projected.distance <= ringRadius + junctionTolerance else { continue }
                let fromA = projected.t * segment.length
                let fromB = (1 - projected.t) * segment.length
                bestAttachmentByNode[segment.a] = min(bestAttachmentByNode[segment.a] ?? .infinity, fromA)
                bestAttachmentByNode[segment.b] = min(bestAttachmentByNode[segment.b] ?? .infinity, fromB)
            }
            let attachments = bestAttachmentByNode.map {
                ActivityGraphAttachment(index: $0.key, weight: $0.value)
            }
            _ = appendLandmark(key: .via(viaIndex), net: net, position: Position3(x, y, 0),
                               attachments: attachments)
        }

        // Add landmarks to the raw centerline graph with zero-length attachment edges. A pad/via is
        // an equipotential piece of copper, so attaching all centerlines it physically contains at
        // zero cost is the right abstraction and naturally handles a trace component touching
        // three or more landmarks without an all-pairs Dijkstra.
        let rawNodeCount = nodes.count
        var graphNeighbors = neighbors
        graphNeighbors.append(contentsOf: repeatElement([], count: landmarks.count))
        func graphIndex(forLandmark index: Int) -> Int { rawNodeCount + index }
        func addGraphEdge(_ a: Int, _ b: Int, weight: Float) {
            guard a != b, weight.isFinite else { return }
            graphNeighbors[a].append((b, weight))
            graphNeighbors[b].append((a, weight))
        }
        for (landmarkIndex, landmark) in landmarks.enumerated() {
            let graphIndex = graphIndex(forLandmark: landmarkIndex)
            for attachment in landmark.attachments {
                addGraphEdge(graphIndex, attachment.index, weight: attachment.weight)
            }
        }

        // The only cross-net graph edges are real two-pin passives. Net membership was filtered by
        // the controller; finish the same spatial test as the real slicer here so a passive on a
        // broad included/ground net cannot connect the activity graph from outside the cut area.
        func landmarkIsInsideCut(_ landmark: ActivityLandmark) -> Bool {
            if activity.includedNets.contains(landmark.net) { return true }
            for net in activity.hullExpandingNets {
                let cutPadding = Float((activity.hullPaddingByNet[net] ?? 0) * Self.simUnitsPerMicrometer)
                for segment in segmentsByNet[net] ?? []
                    where projection(ofX: landmark.x, y: landmark.y, onto: segment).distance <= cutPadding {
                    return true
                }
                if landmarks.contains(where: {
                    guard $0.net == net else { return false }
                    let dx = landmark.x - $0.x
                    let dy = landmark.y - $0.y
                    return (dx * dx + dy * dy).squareRoot() <= cutPadding
                }) {
                    return true
                }
            }
            return false
        }
        for bridge in activity.passiveBridges {
            let firstKey = ActivityLandmarkKey.pin(reference: bridge.reference, number: bridge.firstPad)
            let secondKey = ActivityLandmarkKey.pin(reference: bridge.reference, number: bridge.secondPad)
            guard let first = landmarkIndexByKey[firstKey], let second = landmarkIndexByKey[secondKey] else { continue }
            guard landmarkIsInsideCut(landmarks[first]) || landmarkIsInsideCut(landmarks[second]) else { continue }
            let dx = landmarks[first].x - landmarks[second].x
            let dy = landmarks[first].y - landmarks[second].y
            addGraphEdge(graphIndex(forLandmark: first), graphIndex(forLandmark: second),
                         weight: (dx * dx + dy * dy).squareRoot())
        }

        // One multi-source Dijkstra yields the shortest-path tree rooted at every excitation.
        var graphDistance = [Float](repeating: .infinity, count: graphNeighbors.count)
        var graphQueue = ActivityPriorityQueue()
        for pin in activity.excitedPins {
            let key = ActivityLandmarkKey.pin(reference: pin.reference, number: pin.padNumber)
            guard let index = landmarkIndexByKey[key], landmarks[index].net == pin.netName else { continue }
            let graphIndex = graphIndex(forLandmark: index)
            graphDistance[graphIndex] = 0
            graphQueue.push(node: graphIndex, distance: 0)
        }
        while let current = graphQueue.popMin() {
            guard current.distance <= graphDistance[current.node] else { continue }
            for (neighbor, weight) in graphNeighbors[current.node] {
                let candidate = current.distance + weight
                if candidate < graphDistance[neighbor] {
                    graphDistance[neighbor] = candidate
                    graphQueue.push(node: neighbor, distance: candidate)
                }
            }
        }
        let distanceOfRawNode = Array(graphDistance.prefix(rawNodeCount))
        let landmarkDistance = landmarks.indices.map { graphDistance[graphIndex(forLandmark: $0)] }

        // Visible fill geometry gets phase from its nearest physical centerline. Reachability is
        // decided only after that geometric match: an unreachable fragment must flash, not borrow
        // a pulse from some farther reachable fragment of the same net.
        var positions: [Position3] = []
        var colors: [SIMD4<Float>] = []
        var distances: [Float] = []
        for netName in activity.includedNets {
            let netSegments = segmentsByNet[netName] ?? []
            for (target, targetPositions) in pickPositionsByTarget where target.netName == netName {
                let pinFallback: Float = {
                    guard case let .pin(reference, number, _) = target,
                          let index = landmarkIndexByKey[.pin(reference: reference, number: number)],
                          landmarkDistance[index].isFinite else { return -1 }
                    return landmarkDistance[index]
                }()
                let targetDistances: [Float] = targetPositions.map { vertex in
                    var bestGeometricDistance = Float.infinity
                    var bestSegment: ActivityGraphSegment?
                    var bestT: Float = 0
                    for segment in netSegments {
                        let projected = projection(ofX: vertex.x, y: vertex.y, onto: segment)
                        let dz = vertex.z - segment.z
                        let geometricDistance = (projected.distance * projected.distance + dz * dz).squareRoot()
                        guard geometricDistance < bestGeometricDistance else { continue }
                        bestGeometricDistance = geometricDistance
                        bestSegment = segment
                        bestT = projected.t
                    }
                    guard let segment = bestSegment else { return pinFallback }
                    let fromA = distanceOfRawNode[segment.a]
                    let fromB = distanceOfRawNode[segment.b]
                    guard fromA.isFinite || fromB.isFinite else { return -1 }
                    // One orientation for the whole segment: always increase away from whichever
                    // endpoint is closer to the component's source-facing landmark.
                    return fromA <= fromB ? fromA + bestT * segment.length
                                          : fromB + (1 - bestT) * segment.length
                }
                positions.append(contentsOf: targetPositions)
                colors.append(contentsOf: repeatElement(Self.activityColor, count: targetPositions.count))
                distances.append(contentsOf: targetDistances)
            }
        }
        activityVertexCount = positions.count
        activityPositionBuffer = positions.isEmpty ? nil : device.makeBuffer(
            bytes: positions, length: MemoryLayout<Position3>.stride * positions.count)
        activityColorBuffer = colors.isEmpty ? nil : device.makeBuffer(
            bytes: colors, length: MemoryLayout<SIMD4<Float>>.stride * colors.count)
        activityDistanceBuffer = distances.isEmpty ? nil : device.makeBuffer(
            bytes: distances, length: MemoryLayout<Float>.stride * distances.count)
    }

    /// The real pad positions of `reference`.`padNumber`, if any -- searched by scanning `targets`'
    /// own keys rather than constructing a PickTarget.pin(...) key directly, since that enum's own
    /// `net` associated value would have to match this call's own idea of that pin's net exactly
    /// (nil-vs-empty-string, escaping, ...) for a dictionary lookup to hit. Called rarely (once per
    /// excited pin/passive pad on a rebuild, never per-frame), so the linear scan cost is immaterial.
    private static func positions(reference: String, padNumber: String,
                                   in targets: [PickTarget: [Position3]]) -> [Position3]? {
        for (target, positions) in targets {
            if case let .pin(ref, num, _) = target, ref == reference, num == padNumber {
                return positions
            }
        }
        return nil
    }

    private static func centroid(of positions: [Position3]) -> Position3? {
        guard !positions.isEmpty else { return nil }
        var sum = Position3(0, 0, 0)
        for p in positions {
            sum.x += p.x
            sum.y += p.y
            sum.z += p.z
        }
        let count = Float(positions.count)
        return Position3(sum.x / count, sum.y / count, sum.z / count)
    }

    private static func euclideanDistance(_ a: Position3, _ b: Position3) -> Float {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
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
                                    positions: inout [Position3], colors: inout [SIMD4<Float>],
                                    normals: inout [Position3], muteFlags: inout [Float]) {
        guard radius > 0 else { return }
        let cx = Float(center.x)
        let cy = Float(center.y)
        let r = Float(radius)
        let centerVertex = Position3(cx, cy, z)
        var previous = Position3(cx + r, cy, z)
        for segment in 1...circleSegments {
            let angle = Float(segment) / Float(circleSegments) * 2 * Float.pi
            let current = Position3(cx + r * cos(angle), cy + r * sin(angle), z)
            // Markers are never legacy-net-muted -- they still dim from the region highlight itself
            // (geometry_pbr_fragment applies that independently of muted/muteFlags -- see its own
            // doc comment), just never for this reason.
            appendLitTriangle(centerVertex, previous, current, color: color, muted: false,
                               positions: &positions, colors: &colors, normals: &normals,
                               muteFlags: &muteFlags)
            previous = current
        }
    }

    private static func appendLitTriangle(_ a: Position3, _ b: Position3, _ c: Position3,
                                           color: SIMD4<Float>, muted: Bool,
                                           forceUnmutedByRegion: Bool = false,
                                           positions: inout [Position3],
                                           colors: inout [SIMD4<Float>], normals: inout [Position3],
                                           muteFlags: inout [Float]) {
        let av = SIMD3<Float>(a.x, a.y, a.z)
        let bv = SIMD3<Float>(b.x, b.y, b.z)
        let cv = SIMD3<Float>(c.x, c.y, c.z)
        let crossProduct = cross(bv - av, cv - av)
        let lengthSquared = length_squared(crossProduct)
        let n = lengthSquared > 1e-12 ? normalize(crossProduct) : SIMD3<Float>(0, 0, 1)
        positions.append(contentsOf: [a, b, c])
        colors.append(contentsOf: [color, color, color])
        let packedNormal = Position3(n.x, n.y, n.z)
        normals.append(contentsOf: [packedNormal, packedNormal, packedNormal])
        // -1 means involved signal copper, which belongs to the real cutout at its exact footprint
        // even when it is not a main-excitation hull seed. 0 follows the distance field; +1 stays
        // muted regardless of region membership.
        let flag: Float = muted ? 1 : (forceUnmutedByRegion ? -1 : 0)
        muteFlags.append(contentsOf: [flag, flag, flag])
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
                let color = edgeColors[edge]
                // The C++ preview marks edges whose two XY nodes are external with alpha zero.
                // Omit them from the Metal buffers entirely: the grid pipeline is intentionally
                // opaque, and more importantly an external cell means no shader work exists there,
                // not a differently-coloured simulated region.
                if color.w > 0 {
                    positions.append(contentsOf: [Position3(xLines[x], y, z), Position3(xLines[x + 1], y, z)])
                    colors.append(contentsOf: [color, color])
                }
                edge += 1
            }
        }
        for x in xLines {
            for y in 0..<(yLines.count - 1) {
                let color = edgeColors[edge]
                if color.w > 0 {
                    positions.append(contentsOf: [Position3(x, yLines[y], z), Position3(x, yLines[y + 1], z)])
                    colors.append(contentsOf: [color, color])
                }
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

    /// Tag values for toggleLayerVisibility(_:)'s own sender -- a plain layer index for a copper
    /// layer, or one of these sentinels for geometry which isn't part of `preview.layers` at all
    /// (see EMSGeometryPreview.topSolderMask/bottomSolderMask/componentMeshTriangles).
    private static let topSolderMaskTag = -1
    private static let bottomSolderMaskTag = -2
    private static let componentsTag = -3

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

            let checkbox = Self.makeVisibilityCheckbox(hidden: hiddenLayerIndices.contains(index), tag: index,
                                                          target: self, action: #selector(toggleLayerVisibility(_:)))

            let row = NSStackView(views: [checkbox, swatch, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            legendStack.addArrangedSubview(row)
        }
        // Solder mask isn't part of preview.layers (it's a separate, optionally-nil pair of fields,
        // see topSolderMask/bottomSolderMask's own doc comment) but is real board geometry that can
        // just as easily be the actual source of a rendering artifact -- e.g. overlapping mask
        // triangles read as a darker patch through its own translucent blending (see
        // translucentPipelineState's doc comment) in a way copper's fully-opaque draw never would.
        // Listing it here, toggleable the same as every copper layer, is what makes that isolable
        // from the render instead of just guessed at.
        for (maskLayer, tag, name) in [
            (preview.topSolderMask, Self.topSolderMaskTag, "F.Mask"),
            (preview.bottomSolderMask, Self.bottomSolderMaskTag, "B.Mask"),
        ] {
            guard maskLayer != nil else { continue }
            guard !preview.layers.contains(where: { $0.name == name }) else { continue }
            let swatch = NSBox()
            swatch.boxType = .custom
            swatch.fillColor = Self.solderMaskLegendColor
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .white

            let hidden = tag == Self.topSolderMaskTag ? hideTopSolderMask : hideBottomSolderMask
            let checkbox = Self.makeVisibilityCheckbox(hidden: hidden, tag: tag, target: self,
                                                          action: #selector(toggleLayerVisibility(_:)))

            let row = NSStackView(views: [checkbox, swatch, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            legendStack.addArrangedSubview(row)
        }
        if !preview.componentMeshTriangles.isEmpty {
            let swatch = NSBox()
            swatch.boxType = .custom
            // STEP models can contain many material colors; neutral grey represents the category
            // without falsely implying that every component is rendered with one fixed material.
            swatch.fillColor = NSColor(deviceWhite: 0.65, alpha: 1)
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let label = NSTextField(labelWithString: "Components")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .white

            let checkbox = Self.makeVisibilityCheckbox(hidden: hideComponents, tag: Self.componentsTag,
                                                          target: self, action: #selector(toggleLayerVisibility(_:)))
            let row = NSStackView(views: [checkbox, swatch, label])
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

    /// A plain checkbox (checked = visible), `sender.tag` carrying either a `preview.layers` index or
    /// one of the two solder-mask sentinel tags above -- shared by every legend row's checkbox so
    /// toggleLayerVisibility(_:) only needs to switch on that one tag value.
    private static func makeVisibilityCheckbox(hidden: Bool, tag: Int, target: AnyObject?,
                                                 action: Selector) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "", target: target, action: action)
        checkbox.state = hidden ? .off : .on
        checkbox.tag = tag
        return checkbox
    }

    @objc private func toggleLayerVisibility(_ sender: NSButton) {
        let visible = sender.state == .on
        switch sender.tag {
        case Self.topSolderMaskTag:
            hideTopSolderMask = !visible
        case Self.bottomSolderMaskTag:
            hideBottomSolderMask = !visible
        case Self.componentsTag:
            hideComponents = !visible
        default:
            if visible {
                hiddenLayerIndices.remove(sender.tag)
                if let preview, preview.layers.indices.contains(sender.tag) {
                    let layer = preview.layers[sender.tag]
                    if !layer.geometryGenerated { onLayerNeedsGeometry?(layer.name) }
                }
            } else {
                hiddenLayerIndices.insert(sender.tag)
            }
        }
    }

    // MARK: - Layer color resolution

    /// KiCad's own built-in default color theme, for boards whose active color theme couldn't be
    /// read at all (see EMSGeometryLayer.hexColor's doc comment) -- the same fallback
    /// EMSSimulationPipelineBridge's own libkicad::layerColors() call resolves to when nothing
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
