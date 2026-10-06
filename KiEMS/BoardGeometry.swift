import Foundation
import Metal
import os
import simd

/// Something a click on GeometryView's board can select.
enum BoardPickTarget: Hashable {
    case pin(reference: String, number: String, net: String?)
    case net(String)
    case zone(String?)
    case component(String)
    case hullCutPort(identifier: String, net: String)
    case nets(origin: String, members: [String])

    var netName: String? {
        switch self {
        case let .pin(_, _, net): return net
        case let .net(net): return net
        case let .zone(net): return net
        case .component: return nil
        case let .hullCutPort(_, net): return net
        case let .nets(origin, _): return origin
        }
    }

    /// Pins are submitted after every other pick target in their own depth-biased draw. This
    /// makes a pad win over a nominally coplanar trace without disabling the depth test.
    var hasPickPriority: Bool {
        switch self {
        case .pin, .component, .hullCutPort: return true
        case .net, .zone, .nets: return false
        }
    }
}

/// What decides whether a board vertex is dimmed. Every vertex carries the index of its key, and
/// GeometryView resolves each key against the selected simulation into a small table the shader
/// reads (see geometry_board_pbr_vertex) -- so changing the simulation never touches the geometry.
struct BoardMuteKey: Hashable {
    enum Kind: UInt8 {
        /// Copper, vias and other net-owned geometry: follows its net's inclusion.
        case copper
        /// Silkscreen: as copper, plus muted unless its footprint is involved.
        case silkscreen
        /// STEP model triangles: follow their footprint's involvement / passive-in-cut state.
        case component
    }
    let kind: Kind
    let net: String?
    let footprint: String?

    /// Never muted, never forced inside the region: unnetted copper, solder mask.
    static let neutral = BoardMuteKey(kind: .copper, net: nil, footprint: nil)
}

/// The visibility toggle a run of board vertices belongs to.
enum BoardGeometrySlot: Hashable {
    /// Index into the preview's `layers`, matching GeometryView.hiddenLayerIndices.
    case layer(Int)
    case vias
    case components
    case topSolderMask
    case bottomSolderMask
}

/// Lit triangles in GeometryView's PBR vertex layout, plus each vertex's BoardMuteKey index.
struct BoardLitVertices {
    var positions: [Position3] = []
    var colors: [SIMD4<Float>] = []
    var normals: [Position3] = []
    var keys: [UInt32] = []

    var count: Int { positions.count }

    mutating func appendTriangle(_ a: Position3, _ b: Position3, _ c: Position3,
                                 color: SIMD4<Float>, key: UInt32) {
        let av = SIMD3<Float>(a.x, a.y, a.z)
        let bv = SIMD3<Float>(b.x, b.y, b.z)
        let cv = SIMD3<Float>(c.x, c.y, c.z)
        let crossProduct = cross(bv - av, cv - av)
        let n = length_squared(crossProduct) > 1e-12 ? normalize(crossProduct) : SIMD3<Float>(0, 0, 1)
        let packedNormal = Position3(n.x, n.y, n.z)
        positions.append(contentsOf: [a, b, c])
        colors.append(contentsOf: [color, color, color])
        normals.append(contentsOf: [packedNormal, packedNormal, packedNormal])
        keys.append(contentsOf: [key, key, key])
    }

    mutating func append(_ other: BoardLitVertices, keyMap: [UInt32]) {
        positions.append(contentsOf: other.positions)
        colors.append(contentsOf: other.colors)
        normals.append(contentsOf: other.normals)
        keys.append(contentsOf: other.keys.map { keyMap[Int($0)] })
    }
}

/// The GPU copy of a BoardLitVertices stream.
struct BoardLitBuffers {
    let positions: MTLBuffer
    let colors: MTLBuffer
    let normals: MTLBuffer
    let keys: MTLBuffer

    init?(device: MTLDevice, vertices: BoardLitVertices) {
        guard vertices.count > 0,
              let positions = device.makeBuffer(bytes: vertices.positions,
                                                length: MemoryLayout<Position3>.stride * vertices.count),
              let colors = device.makeBuffer(bytes: vertices.colors,
                                             length: MemoryLayout<SIMD4<Float>>.stride * vertices.count),
              let normals = device.makeBuffer(bytes: vertices.normals,
                                              length: MemoryLayout<Position3>.stride * vertices.count),
              let keys = device.makeBuffer(bytes: vertices.keys,
                                           length: MemoryLayout<UInt32>.stride * vertices.count)
        else { return nil }
        self.positions = positions
        self.colors = colors
        self.normals = normals
        self.keys = keys
    }
}

/// Everything GeometryView draws for a preview's board, independent of which layers are shown and
/// which simulation is selected. Built once per preview revision, off the main thread (see
/// BoardGeometryBuilder); visibility picks ranges out of it and muting is a per-key lookup.
/// Immutable once built, so it can be read from any thread.
final class BoardGeometry {
    /// Opaque copper/silkscreen/fab, vias and STEP components, back-to-front by layer.
    let opaque: BoardLitBuffers?
    let opaqueRanges: [BoardGeometrySlot: Range<Int>]
    /// Translucent zone pours, back-to-front by layer.
    let zone: BoardLitBuffers?
    let zoneRanges: [BoardGeometrySlot: Range<Int>]
    /// Solder mask, from mask layers in `layers` and the stackup's own top/bottom masks.
    let mask: BoardLitBuffers?
    let maskRanges: [BoardGeometrySlot: Range<Int>]

    let pickPositions: MTLBuffer?
    let pickIdentifiers: MTLBuffer?
    /// Drawn with ordinary depth.
    let pickRanges: [BoardGeometrySlot: Range<Int>]
    /// Pins: drawn after pickRanges with a small toward-camera bias.
    let pickPriorityRanges: [BoardGeometrySlot: Range<Int>]
    /// STEP-model pick geometry per footprint. Only invalid components are pickable, so these are
    /// drawn (with the priority bias) for just those references.
    let componentPickRanges: [String: Range<Int>]
    let targetsByIdentifier: [UInt32: BoardPickTarget]

    /// Pick geometry per target, split by the slot it came from so hidden layers can be skipped.
    let positionsByTarget: [BoardPickTarget: [(slot: BoardGeometrySlot, positions: [Position3])]]
    /// "reference\tnumber" -> its .pin target, for pin lookups that don't know the pin's net.
    let pinTargets: [String: BoardPickTarget]

    /// Every netted copper triangle on every layer (hidden or not) and every netted via, grouped by
    /// net -- the hull distance field's seeds. Kept on the CPU too for the passive in-cut test.
    let seedPositions: [Position3]
    let seedBuffer: MTLBuffer?
    let seedRangesByNet: [String: Range<Int>]

    let muteKeys: [BoardMuteKey]

    let outlineBuffer: MTLBuffer?
    let outlineColorBuffer: MTLBuffer?
    let outlineVertexCount: Int

    fileprivate init(opaque: BoardLitBuffers?, opaqueRanges: [BoardGeometrySlot: Range<Int>],
                     zone: BoardLitBuffers?, zoneRanges: [BoardGeometrySlot: Range<Int>],
                     mask: BoardLitBuffers?, maskRanges: [BoardGeometrySlot: Range<Int>],
                     pickPositions: MTLBuffer?, pickIdentifiers: MTLBuffer?,
                     pickRanges: [BoardGeometrySlot: Range<Int>],
                     pickPriorityRanges: [BoardGeometrySlot: Range<Int>],
                     componentPickRanges: [String: Range<Int>],
                     targetsByIdentifier: [UInt32: BoardPickTarget],
                     positionsByTarget: [BoardPickTarget: [(slot: BoardGeometrySlot, positions: [Position3])]],
                     pinTargets: [String: BoardPickTarget],
                     seedPositions: [Position3], seedBuffer: MTLBuffer?, seedRangesByNet: [String: Range<Int>],
                     muteKeys: [BoardMuteKey],
                     outlineBuffer: MTLBuffer?, outlineColorBuffer: MTLBuffer?, outlineVertexCount: Int) {
        self.opaque = opaque
        self.opaqueRanges = opaqueRanges
        self.zone = zone
        self.zoneRanges = zoneRanges
        self.mask = mask
        self.maskRanges = maskRanges
        self.pickPositions = pickPositions
        self.pickIdentifiers = pickIdentifiers
        self.pickRanges = pickRanges
        self.pickPriorityRanges = pickPriorityRanges
        self.componentPickRanges = componentPickRanges
        self.targetsByIdentifier = targetsByIdentifier
        self.positionsByTarget = positionsByTarget
        self.pinTargets = pinTargets
        self.seedPositions = seedPositions
        self.seedBuffer = seedBuffer
        self.seedRangesByNet = seedRangesByNet
        self.muteKeys = muteKeys
        self.outlineBuffer = outlineBuffer
        self.outlineColorBuffer = outlineColorBuffer
        self.outlineVertexCount = outlineVertexCount
    }

    /// The ranges of `ranges` whose slot is visible, in buffer order with adjacent runs merged, so
    /// an all-visible board is still one draw call.
    static func drawRanges(_ ranges: [BoardGeometrySlot: Range<Int>],
                           isVisible: (BoardGeometrySlot) -> Bool) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.compactMap({ isVisible($0.key) && !$0.value.isEmpty ? $0.value : nil })
            .sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, last.upperBound == range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<range.upperBound
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// The main-thread inputs to a BoardGeometry build. The triangle arrays are immutable snapshots,
/// so the build can read them while the main thread fills further layers in.
struct BoardGeometrySnapshot {
    struct Layer {
        let slot: BoardGeometrySlot
        let layer: EMSGeometryLayer
        let revision: UInt
        let name: String
        let z: Float
        /// The solder-mask color for mask layers.
        let color: SIMD4<Float>
        let triangles: [EMSGeometryTriangle]
        /// Everything goes to the translucent mask stream (the stackup's own top/bottom masks).
        let isStackupMask: Bool
    }
    let preview: EMSGeometryPreview
    let previewRevision: UInt
    /// Back-to-front.
    let layers: [Layer]
    let viaMeshTriangles: [EMSGeometryComponentTriangle]
    let componentMeshTriangles: [EMSGeometryComponentTriangle]
    let outline: [CGPoint]
    let markerZ: Float
    let outlineColor: SIMD4<Float>
}

/// One layer's (or the vias'/components') tessellation, with targets and mute keys local to it so
/// it can be cached and reused unchanged when another layer arrives.
private final class BoardGeometryChunk {
    var opaque = BoardLitVertices()
    var zone = BoardLitVertices()
    var mask = BoardLitVertices()
    var pickPositions: [Position3] = []
    var pickTargets: [Int32] = []
    var priorityPickPositions: [Position3] = []
    var priorityPickTargets: [Int32] = []
    /// Component pick geometry by footprint (local target is always .component(reference)).
    var componentPickPositions: [String: [Position3]] = [:]
    var positionsByTarget: [Int: [Position3]] = [:]
    var seedsByNet: [String: [Position3]] = [:]

    private(set) var targets: [BoardPickTarget] = []
    private var targetIndex: [BoardPickTarget: Int32] = [:]
    private(set) var keys: [BoardMuteKey] = []
    private var keyIndex: [BoardMuteKey: UInt32] = [:]

    func target(_ target: BoardPickTarget) -> Int32 {
        if let existing = targetIndex[target] { return existing }
        let index = Int32(targets.count)
        targets.append(target)
        targetIndex[target] = index
        return index
    }

    func key(_ key: BoardMuteKey) -> UInt32 {
        if let existing = keyIndex[key] { return existing }
        let index = UInt32(keys.count)
        keys.append(key)
        keyIndex[key] = index
        return index
    }

    func addPick(_ vertices: [Position3], target: BoardPickTarget) {
        let index = self.target(target)
        if target.hasPickPriority {
            priorityPickPositions.append(contentsOf: vertices)
            priorityPickTargets.append(contentsOf: repeatElement(index, count: vertices.count))
        } else {
            pickPositions.append(contentsOf: vertices)
            pickTargets.append(contentsOf: repeatElement(index, count: vertices.count))
        }
        positionsByTarget[Int(index), default: []].append(contentsOf: vertices)
    }

    static func layer(_ layer: BoardGeometrySnapshot.Layer) -> BoardGeometryChunk {
        let chunk = BoardGeometryChunk()
        let z = layer.z
        if layer.isStackupMask {
            let key = chunk.key(.neutral)
            for triangle in layer.triangles {
                chunk.mask.appendTriangle(Position3(Float(triangle.a.x), Float(triangle.a.y), z),
                                          Position3(Float(triangle.b.x), Float(triangle.b.y), z),
                                          Position3(Float(triangle.c.x), Float(triangle.c.y), z),
                                          color: layer.color, key: key)
            }
            return chunk
        }
        let isSolderMaskLayer = layer.name == "F.Mask" || layer.name == "B.Mask"
        let isSilkscreen = layer.name == "F.Silkscreen" || layer.name == "B.Silkscreen"
        for triangle in layer.triangles {
            let a = Position3(Float(triangle.a.x), Float(triangle.a.y), z)
            let b = Position3(Float(triangle.b.x), Float(triangle.b.y), z)
            let c = Position3(Float(triangle.c.x), Float(triangle.c.y), z)
            // Dynamically loaded mask lives in preview.layers so the list exactly mirrors KiCad,
            // but it must still use the dedicated mask pass. Treating its 0.45 opacity as an
            // ordinary zone put it in the zone stream, where it blended over copper.
            if isSolderMaskLayer {
                chunk.mask.appendTriangle(a, b, c, color: layer.color, key: chunk.key(.neutral))
                continue
            }
            // Every netted triangle seeds the slicing hull, whether or not its layer is shown.
            if let netName = triangle.netName {
                chunk.seedsByNet[netName, default: []].append(contentsOf: [a, b, c])
            }
            // Alpha 0 is the "no override" sentinel (see EMSGeometryTriangle.color's own doc
            // comment) -- real copper is always fully opaque, so a real per-triangle color never
            // collides with it.
            let color = triangle.color.w > 0
                ? SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y), Float(triangle.color.z),
                               Float(triangle.color.w))
                : layer.color
            let key = chunk.key(isSilkscreen
                ? BoardMuteKey(kind: .silkscreen, net: triangle.netName, footprint: triangle.footprintReference)
                : BoardMuteKey(kind: .copper, net: triangle.netName, footprint: nil))
            let pickTarget: BoardPickTarget?
            switch triangle.kind {
            case .pin:
                pickTarget = triangle.footprintReference.map {
                    .pin(reference: $0, number: triangle.padNumber ?? "", net: triangle.netName)
                }
            case .trace:
                pickTarget = triangle.netName.map(BoardPickTarget.net)
            case .zone:
                pickTarget = .zone(triangle.netName)
            default:
                pickTarget = nil
            }
            if triangle.opacity < 1 {
                var translucentColor = color
                translucentColor.w = Float(triangle.opacity)
                // One simulation unit (0.1 micron) behind this layer's opaque copper: enough to
                // make tracks/pads win the depth test without visibly separating the pour.
                let zoneA = Position3(a.x, a.y, z - 1)
                let zoneB = Position3(b.x, b.y, z - 1)
                let zoneC = Position3(c.x, c.y, z - 1)
                chunk.zone.appendTriangle(zoneA, zoneB, zoneC, color: translucentColor, key: key)
                if let pickTarget { chunk.addPick([zoneA, zoneB, zoneC], target: pickTarget) }
            } else {
                chunk.opaque.appendTriangle(a, b, c, color: color, key: key)
                if let pickTarget { chunk.addPick([a, b, c], target: pickTarget) }
            }
        }
        return chunk
    }

    /// Real 3D via geometry (open barrel tube + per-layer annular rings -- see
    /// EMSGeometryPreview.viaMeshTriangles' own doc comment). Each vertex keeps its own real Z.
    static func vias(_ triangles: [EMSGeometryComponentTriangle]) -> BoardGeometryChunk {
        let chunk = BoardGeometryChunk()
        for triangle in triangles {
            let color = SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y), Float(triangle.color.z),
                                      Float(triangle.color.w))
            let a = Position3(Float(triangle.a.x), Float(triangle.a.y), Float(triangle.a.z))
            let b = Position3(Float(triangle.b.x), Float(triangle.b.y), Float(triangle.b.z))
            let c = Position3(Float(triangle.c.x), Float(triangle.c.y), Float(triangle.c.z))
            chunk.opaque.appendTriangle(a, b, c, color: color,
                                        key: chunk.key(BoardMuteKey(kind: .copper, net: triangle.netName,
                                                                    footprint: nil)))
            guard let netName = triangle.netName else { continue }
            chunk.seedsByNet[netName, default: []].append(contentsOf: [a, b, c])
            chunk.addPick([a, b, c], target: .net(netName))
        }
        return chunk
    }

    /// Real 3D models of every included footprint, each vertex at its own real Z, in the model's
    /// own STEP color (the invalid-component tint is applied by the shader from the mute table).
    static func components(_ triangles: [EMSGeometryComponentTriangle]) -> BoardGeometryChunk {
        let chunk = BoardGeometryChunk()
        for triangle in triangles {
            let color = SIMD4<Float>(Float(triangle.color.x), Float(triangle.color.y), Float(triangle.color.z),
                                      Float(triangle.color.w))
            let a = Position3(Float(triangle.a.x), Float(triangle.a.y), Float(triangle.a.z))
            let b = Position3(Float(triangle.b.x), Float(triangle.b.y), Float(triangle.b.z))
            let c = Position3(Float(triangle.c.x), Float(triangle.c.y), Float(triangle.c.z))
            chunk.opaque.appendTriangle(a, b, c, color: color,
                                        key: chunk.key(BoardMuteKey(kind: .component, net: nil,
                                                                    footprint: triangle.footprintReference)))
            if let reference = triangle.footprintReference {
                chunk.componentPickPositions[reference, default: []].append(contentsOf: [a, b, c])
            }
        }
        return chunk
    }
}

/// Builds BoardGeometry on a background queue, reusing each layer's tessellation for as long as
/// that layer's revision is unchanged -- so a layer arriving only tessellates itself, and the
/// rest is concatenation. Requests made while a build is running coalesce into one follow-up.
/// Owned by one GeometryView; all mutable state lives on `queue` (or behind `pending`'s lock).
final class BoardGeometryBuilder {
    private let device: MTLDevice
    private let queue = DispatchQueue(label: "com.kiems.board-geometry", qos: .userInitiated)
    private let pending = OSAllocatedUnfairLock<(snapshot: BoardGeometrySnapshot,
                                                 completion: (BoardGeometrySnapshot, BoardGeometry) -> Void)?>(
        initialState: nil)

    // Queue-confined caches.
    private struct LayerCacheEntry {
        let layer: EMSGeometryLayer
        let revision: UInt
        let z: Float
        let color: SIMD4<Float>
        let chunk: BoardGeometryChunk
    }
    private var layerCache: [ObjectIdentifier: LayerCacheEntry] = [:]
    private var meshCache: (preview: EMSGeometryPreview, revision: UInt,
                            vias: BoardGeometryChunk, components: BoardGeometryChunk)?

    init(device: MTLDevice) {
        self.device = device
    }

    /// Builds `snapshot` (or a later one, if another request arrives first) and calls `completion`
    /// on the main thread.
    func build(_ snapshot: BoardGeometrySnapshot,
               completion: @escaping (BoardGeometrySnapshot, BoardGeometry) -> Void) {
        pending.withLock { $0 = (snapshot, completion) }
        queue.async { [weak self] in
            guard let self, let request = self.pending.withLock({ state in
                defer { state = nil }
                return state
            }) else { return }
            let signposter = OSSignposter(subsystem: "com.kiems", category: "BoardLoad")
            let signpost = signposter.beginInterval("Assemble board geometry", id: signposter.makeSignpostID())
            let geometry = self.assemble(request.snapshot)
            signposter.endInterval("Assemble board geometry", signpost)
            let delivery = signposter.beginInterval("Geometry main queue delivery", id: signposter.makeSignpostID())
            DispatchQueue.main.async {
                signposter.endInterval("Geometry main queue delivery", delivery)
                request.completion(request.snapshot, geometry)
            }
        }
    }

    private func cachedChunk(for layer: BoardGeometrySnapshot.Layer) -> BoardGeometryChunk? {
        guard let cached = layerCache[ObjectIdentifier(layer.layer)], cached.revision == layer.revision,
              cached.z == layer.z, cached.color == layer.color else { return nil }
        return cached.chunk
    }

    /// Converts one layer without touching any builder state, so layers can convert concurrently.
    private static func makeChunk(for layer: BoardGeometrySnapshot.Layer) -> BoardGeometryChunk {
        let signposter = OSSignposter(subsystem: "com.kiems", category: "BoardLoad")
        let timing = signposter.beginInterval("Layer chunk", id: signposter.makeSignpostID(), "\(layer.name, privacy: .public) triangles=\(layer.triangles.count)")
        defer { signposter.endInterval("Layer chunk", timing) }
        return BoardGeometryChunk.layer(layer)
    }

    private func assemble(_ snapshot: BoardGeometrySnapshot) -> BoardGeometry {
        let signposter = OSSignposter(subsystem: "com.kiems", category: "BoardLoad")
        let chunksTiming = signposter.beginInterval("Geometry chunks", id: signposter.makeSignpostID())
        let live = Set(snapshot.layers.map { ObjectIdentifier($0.layer) })
        layerCache = layerCache.filter { live.contains($0.key) }
        let meshesCached = meshCache.map {
            $0.preview === snapshot.preview && $0.revision == snapshot.previewRevision
        } ?? false

        // Every stale layer, and the via/component meshes, convert independently from their own
        // immutable inputs into fresh chunks. On a first load that is every layer, so convert
        // them concurrently; only the cache updates afterwards touch builder state.
        let staleLayers = snapshot.layers.indices.filter { cachedChunk(for: snapshot.layers[$0]) == nil }
        let jobCount = staleLayers.count + (meshesCached ? 0 : 2)
        var built = [BoardGeometryChunk?](repeating: nil, count: jobCount)
        built.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: jobCount) { job in
                if job < staleLayers.count {
                    results[job] = Self.makeChunk(for: snapshot.layers[staleLayers[job]])
                } else if job == staleLayers.count {
                    results[job] = BoardGeometryChunk.vias(snapshot.viaMeshTriangles)
                } else {
                    results[job] = BoardGeometryChunk.components(snapshot.componentMeshTriangles)
                }
            }
        }
        for (job, layerIndex) in staleLayers.enumerated() {
            let layer = snapshot.layers[layerIndex]
            layerCache[ObjectIdentifier(layer.layer)] = LayerCacheEntry(
                layer: layer.layer, revision: layer.revision, z: layer.z, color: layer.color, chunk: built[job]!)
        }
        if !meshesCached {
            meshCache = (snapshot.preview, snapshot.previewRevision,
                         built[staleLayers.count]!, built[staleLayers.count + 1]!)
        }
        let meshes = (vias: meshCache!.vias, components: meshCache!.components)
        var chunks: [(slot: BoardGeometrySlot, chunk: BoardGeometryChunk)] =
            snapshot.layers.map { ($0.slot, cachedChunk(for: $0)!) }
        chunks.append((.vias, meshes.vias))
        chunks.append((.components, meshes.components))

        signposter.endInterval("Geometry chunks", chunksTiming)
        let mergeTiming = signposter.beginInterval("Geometry merge and remap", id: signposter.makeSignpostID())
        var opaque = BoardLitVertices(), zone = BoardLitVertices(), mask = BoardLitVertices()
        var opaqueRanges: [BoardGeometrySlot: Range<Int>] = [:]
        var zoneRanges: [BoardGeometrySlot: Range<Int>] = [:]
        var maskRanges: [BoardGeometrySlot: Range<Int>] = [:]
        var muteKeys: [BoardMuteKey] = []
        var muteKeyIndex: [BoardMuteKey: UInt32] = [:]
        var targetsByIdentifier: [UInt32: BoardPickTarget] = [:]
        var identifierByTarget: [BoardPickTarget: UInt32] = [:]
        var positionsByTarget: [BoardPickTarget: [(slot: BoardGeometrySlot, positions: [Position3])]] = [:]
        var seedsByNet: [String: [Position3]] = [:]
        var pickPositions: [Position3] = [], pickIdentifiers: [UInt32] = []
        var priorityPositions: [Position3] = [], priorityIdentifiers: [UInt32] = []
        var normalPickRanges: [BoardGeometrySlot: Range<Int>] = [:]
        var priorityPickRanges: [BoardGeometrySlot: Range<Int>] = [:]
        var componentPickRanges: [String: Range<Int>] = [:]

        func identifier(for target: BoardPickTarget) -> UInt32 {
            if let existing = identifierByTarget[target] { return existing }
            let identifier = UInt32(identifierByTarget.count + 1) // 0 is the cleared background.
            identifierByTarget[target] = identifier
            targetsByIdentifier[identifier] = target
            return identifier
        }

        for (slot, chunk) in chunks {
            let keyMap: [UInt32] = chunk.keys.map { key in
                if let existing = muteKeyIndex[key] { return existing }
                let index = UInt32(muteKeys.count)
                muteKeys.append(key)
                muteKeyIndex[key] = index
                return index
            }
            let targetMap = chunk.targets.map(identifier(for:))
            func appendStream(_ stream: BoardLitVertices, into all: inout BoardLitVertices,
                              ranges: inout [BoardGeometrySlot: Range<Int>]) {
                guard stream.count > 0 else { return }
                let start = all.count
                all.append(stream, keyMap: keyMap)
                ranges[slot] = start..<all.count
            }
            appendStream(chunk.opaque, into: &opaque, ranges: &opaqueRanges)
            appendStream(chunk.zone, into: &zone, ranges: &zoneRanges)
            appendStream(chunk.mask, into: &mask, ranges: &maskRanges)

            if !chunk.pickPositions.isEmpty {
                let start = pickPositions.count
                pickPositions.append(contentsOf: chunk.pickPositions)
                pickIdentifiers.append(contentsOf: chunk.pickTargets.map { targetMap[Int($0)] })
                normalPickRanges[slot] = start..<pickPositions.count
            }
            if !chunk.priorityPickPositions.isEmpty {
                let start = priorityPositions.count
                priorityPositions.append(contentsOf: chunk.priorityPickPositions)
                priorityIdentifiers.append(contentsOf: chunk.priorityPickTargets.map { targetMap[Int($0)] })
                priorityPickRanges[slot] = start..<priorityPositions.count
            }
            for (reference, positions) in chunk.componentPickPositions {
                let target = BoardPickTarget.component(reference)
                let id = identifier(for: target)
                let start = priorityPositions.count
                priorityPositions.append(contentsOf: positions)
                priorityIdentifiers.append(contentsOf: repeatElement(id, count: positions.count))
                componentPickRanges[reference] = start..<priorityPositions.count
                positionsByTarget[target, default: []].append((slot, positions))
            }
            for (localTarget, positions) in chunk.positionsByTarget {
                positionsByTarget[chunk.targets[localTarget], default: []].append((slot, positions))
            }
            for (net, positions) in chunk.seedsByNet {
                seedsByNet[net, default: []].append(contentsOf: positions)
            }
        }

        // Pins and components follow every other pick target so their depth-biased draw wins
        // coplanar ties (see GeometryView.pick(at:)).
        let priorityOffset = pickPositions.count
        pickPositions.append(contentsOf: priorityPositions)
        pickIdentifiers.append(contentsOf: priorityIdentifiers)
        let shift = { (range: Range<Int>) in (range.lowerBound + priorityOffset)..<(range.upperBound + priorityOffset) }
        priorityPickRanges = priorityPickRanges.mapValues(shift)
        componentPickRanges = componentPickRanges.mapValues(shift)

        var pinTargets: [String: BoardPickTarget] = [:]
        for target in positionsByTarget.keys {
            if case let .pin(reference, number, _) = target {
                pinTargets["\(reference)\t\(number)"] = target
            }
        }

        var seedPositions: [Position3] = []
        var seedRangesByNet: [String: Range<Int>] = [:]
        for (net, positions) in seedsByNet {
            let start = seedPositions.count
            seedPositions.append(contentsOf: positions)
            seedRangesByNet[net] = start..<seedPositions.count
        }

        var outlinePositions = snapshot.outline.map { Position3(Float($0.x), Float($0.y), snapshot.markerZ) }
        if let first = outlinePositions.first { outlinePositions.append(first) } // Close the loop.
        let outlineColors = Array(repeating: snapshot.outlineColor, count: outlinePositions.count)

        signposter.endInterval("Geometry merge and remap", mergeTiming)
        let buffersTiming = signposter.beginInterval("Geometry Metal buffers", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Geometry Metal buffers", buffersTiming) }
        func buffer<T: BitwiseCopyable>(_ values: [T]) -> MTLBuffer? {
            values.withUnsafeBytes { bytes in
                bytes.isEmpty ? nil : device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
            }
        }
        return BoardGeometry(
            opaque: BoardLitBuffers(device: device, vertices: opaque), opaqueRanges: opaqueRanges,
            zone: BoardLitBuffers(device: device, vertices: zone), zoneRanges: zoneRanges,
            mask: BoardLitBuffers(device: device, vertices: mask), maskRanges: maskRanges,
            pickPositions: buffer(pickPositions), pickIdentifiers: buffer(pickIdentifiers),
            pickRanges: normalPickRanges, pickPriorityRanges: priorityPickRanges,
            componentPickRanges: componentPickRanges, targetsByIdentifier: targetsByIdentifier,
            positionsByTarget: positionsByTarget, pinTargets: pinTargets,
            seedPositions: seedPositions, seedBuffer: buffer(seedPositions), seedRangesByNet: seedRangesByNet,
            muteKeys: muteKeys,
            outlineBuffer: buffer(outlinePositions), outlineColorBuffer: buffer(outlineColors),
            outlineVertexCount: outlinePositions.count)
    }
}
