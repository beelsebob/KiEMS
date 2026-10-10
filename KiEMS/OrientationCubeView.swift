import Cocoa
import simd

/// A small labelled cube showing the orbit camera's current orientation, drawn with Core Graphics
/// as an overlay subview of GeometryView. The owner pushes the camera basis in via
/// update(right:up:eyeDirection:) each frame; clicking a face asks the owner to look along it.
final class OrientationCubeView: NSView {
    struct Face {
        let label: String
        /// Outward normal in world coordinates -- also the direction from target to eye when
        /// looking straight at this face.
        let normal: SIMD3<Float>
        /// In-face text axes, chosen so u x v == normal (the projected label is then never mirrored).
        let u: SIMD3<Float>
        let v: SIMD3<Float>
    }

    static let faces: [Face] = [
        Face(label: "TOP", normal: [0, 0, 1], u: [1, 0, 0], v: [0, 1, 0]),
        Face(label: "BOTTOM", normal: [0, 0, -1], u: [1, 0, 0], v: [0, -1, 0]),
        Face(label: "FRONT", normal: [0, -1, 0], u: [1, 0, 0], v: [0, 0, 1]),
        Face(label: "BACK", normal: [0, 1, 0], u: [-1, 0, 0], v: [0, 0, 1]),
        Face(label: "RIGHT", normal: [1, 0, 0], u: [0, 1, 0], v: [0, 0, 1]),
        Face(label: "LEFT", normal: [-1, 0, 0], u: [0, -1, 0], v: [0, 0, 1]),
    ]

    var onSelectFace: ((Face) -> Void)?
    /// Called with `true` for the top-right (clockwise) roll button, `false` for the top-left one.
    var onRoll: ((Bool) -> Void)?

    private lazy var rollLeftButton = makeRollButton(symbol: "arrow.counterclockwise", clockwise: false)
    private lazy var rollRightButton = makeRollButton(symbol: "arrow.clockwise", clockwise: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [rollLeftButton, rollRightButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: topAnchor),
                button.widthAnchor.constraint(equalToConstant: 18),
                button.heightAnchor.constraint(equalToConstant: 18),
            ])
        }
        rollLeftButton.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
        rollRightButton.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeRollButton(symbol: String, clockwise: Bool) -> NSButton {
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: clockwise ? "Roll clockwise" : "Roll counterclockwise")
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(rollButtonPressed(_:)))
        button.isBordered = false
        button.contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 0.9)
        button.toolTip = clockwise ? "Roll clockwise" : "Roll counterclockwise"
        button.tag = clockwise ? 1 : 0
        return button
    }

    @objc private func rollButtonPressed(_ sender: NSButton) {
        onRoll?(sender.tag == 1)
    }

    private var right = SIMD3<Float>(1, 0, 0)
    private var up = SIMD3<Float>(0, 1, 0)
    private var eyeDirection = SIMD3<Float>(0, 0, 1)
    private var hoveredFaceIndex: Int?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    func update(right: SIMD3<Float>, up: SIMD3<Float>, eyeDirection: SIMD3<Float>) {
        guard right != self.right || up != self.up || eyeDirection != self.eyeDirection else { return }
        self.right = right
        self.up = up
        self.eyeDirection = eyeDirection
        needsDisplay = true
    }

    /// Half the cube's edge length in points; leaves room for the corners at any orientation.
    private var halfSize: CGFloat { min(bounds.width, bounds.height) / (2 * sqrt(3)) * 0.95 }

    private func project(_ p: SIMD3<Float>) -> CGPoint {
        CGPoint(x: bounds.midX + CGFloat(simd_dot(p, right)) * halfSize,
                y: bounds.midY + CGFloat(simd_dot(p, up)) * halfSize)
    }

    private func corners(of face: Face) -> [CGPoint] {
        let n = face.normal, u = face.u, v = face.v
        return [n - u - v, n + u - v, n + u + v, n - u + v].map(project)
    }

    /// Faces turned toward the camera, farthest first.
    private func visibleFaceIndices() -> [Int] {
        Self.faces.indices
            .filter { simd_dot(Self.faces[$0].normal, eyeDirection) > 1e-3 }
            .sorted { simd_dot(Self.faces[$0].normal, eyeDirection) < simd_dot(Self.faces[$1].normal, eyeDirection) }
    }

    private func path(for face: Face) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: corners(of: face))
        path.closeSubpath()
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for index in visibleFaceIndices() {
            let face = Self.faces[index]
            let facing = CGFloat(simd_dot(face.normal, eyeDirection))
            let path = path(for: face)
            let base: CGFloat = index == hoveredFaceIndex ? 0.55 : 0.32 + 0.18 * facing
            context.addPath(path)
            context.setFillColor(NSColor(calibratedWhite: base, alpha: 0.85).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(NSColor(calibratedWhite: 0.85, alpha: 0.9).cgColor)
            context.setLineWidth(1)
            context.strokePath()

            // Label, drawn in the face's own (u, v) frame and mapped onto its projection.
            let center = project(face.normal)
            let ux = CGFloat(simd_dot(face.u, right)), uy = CGFloat(simd_dot(face.u, up))
            let vx = CGFloat(simd_dot(face.v, right)), vy = CGFloat(simd_dot(face.v, up))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: halfSize * 0.38, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: min(1, 0.3 + facing)),
            ]
            let text = NSAttributedString(string: face.label, attributes: attributes)
            let textSize = text.size()
            let scale = min(1, halfSize * 1.8 / max(textSize.width, 1))
            context.saveGState()
            context.concatenate(CGAffineTransform(a: ux * scale, b: uy * scale, c: vx * scale, d: vy * scale,
                                                  tx: center.x, ty: center.y))
            text.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2))
            context.restoreGState()
        }
    }

    private func faceIndex(at point: CGPoint) -> Int? {
        visibleFaceIndices().reversed().first { path(for: Self.faces[$0]).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = faceIndex(at: convert(event.locationInWindow, from: nil))
        if index != hoveredFaceIndex {
            hoveredFaceIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredFaceIndex = nil
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let drags over the cube's empty corners fall through to the 3D view.
        if let button = super.hitTest(point) as? NSButton { return button }
        let local = convert(point, from: superview)
        return faceIndex(at: local) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = faceIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onSelectFace?(Self.faces[index])
    }
}
