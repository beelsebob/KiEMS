import AppKit
import Metal

/// The shared field-energy colour ramp. Keeping the interpolation here lets density plots and the
/// 3D field viewer use identical colours without sharing either renderer's implementation details.
public enum EnergyColorMap {
    private static let stops: [(t: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat)] = [
        (0.0, 0x2a / 255, 0x2e / 255, 0xac / 255),
        (0.5, 0xb8 / 255, 0x1f / 255, 0x3c / 255),
        (0.75, 0xf0 / 255, 0x7f / 255, 0x29 / 255),
        (0.875, 0xfa / 255, 0xa9 / 255, 0x14 / 255),
        (1.0, 0xf2 / 255, 0xce / 255, 0x30 / 255),
    ]

    public static func rgb(at value: CGFloat) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let clamped = min(max(value, 0), 1)
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for index in 0..<(stops.count - 1) where clamped >= stops[index].t && clamped <= stops[index + 1].t {
            lower = stops[index]
            upper = stops[index + 1]
            break
        }
        let span = upper.t - lower.t
        let fraction = span > 0 ? (clamped - lower.t) / span : 0
        return (lower.red + (upper.red - lower.red) * fraction,
                lower.green + (upper.green - lower.green) * fraction,
                lower.blue + (upper.blue - lower.blue) * fraction)
    }

    /// Eye-density opacity: empty/very-low-density pixels reveal the chart background, ramping
    /// linearly to fully opaque over the first quarter of the normalized colour range. The field
    /// viewer deliberately continues to use rgb(at:) with its own spatial-opacity mapping.
    public static func rgba(at value: CGFloat) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let rgb = rgb(at: value)
        let alpha = min(max(value / 0.25, 0), 1)
        return (rgb.red, rgb.green, rgb.blue, alpha)
    }
}

/// Dense two-unit-interval eye plot. Every received bit slice is drawn on the same axis with a
/// translucent stroke; crossings and the open eye emerge from the accumulated traces rather than
/// from a precomputed envelope.
public final class EyeDiagramView: NSView {
    private var timeUI: [Double] = []
    private var traces: [[Double]] = []
    /// Symmetric y extent of the traces; nil when there is no finite sample. Computed once per
    /// setData rather than rescanning every sample on each draw.
    private var magnitude: Double?
    /// The rendered density image and the pixel size it was rendered at. Rasterizing every trace is
    /// by far the most expensive part of drawing, so it is only redone when the data changes or the
    /// plot's pixel dimensions do (resize or a move to a display with a different backing scale).
    private var cachedDensity: (image: CGImage, width: Int, height: Int)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 600).isActive = true
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func setData(timeUI: [Double], traces: [[Double]]) {
        self.timeUI = timeUI
        self.traces = traces.filter { $0.count == timeUI.count }
        var rawMin = Double.infinity
        var rawMax = -Double.infinity
        for trace in self.traces {
            for value in trace where value.isFinite {
                rawMin = min(rawMin, value)
                rawMax = max(rawMax, value)
            }
        }
        magnitude = rawMin <= rawMax ? max(abs(rawMin), abs(rawMax), 1e-12) * 1.08 : nil
        cachedDensity = nil
        needsDisplay = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard timeUI.count > 1, !traces.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

        let plot = bounds.insetBy(dx: 52, dy: 30).offsetBy(dx: 8, dy: 8)
        guard plot.width > 1, plot.height > 1 else { return }

        guard let magnitude else { return }
        let xMin = timeUI.first ?? -0.5
        let xMax = timeUI.last ?? 1.5

        func point(x: Double, y: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((x - xMin) / (xMax - xMin)) * plot.width,
                    y: plot.midY + CGFloat(y / magnitude) * plot.height / 2)
        }

        context.saveGState()
        context.addPath(CGPath(roundedRect: plot, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.clip()

        // Accumulate every trace into a grayscale density image first. Ten-percent white strokes
        // over black naturally encode overlap count as brightness; converting that finished image
        // through EnergyColorMap afterwards avoids alpha-order artefacts in the final display.
        if let density = cachedDensityImage(size: plot.size, magnitude: magnitude, xMin: xMin, xMax: xMax) {
            context.interpolationQuality = .none
            context.draw(density, in: plot)
        }

        context.setLineWidth(0.5)
        context.setStrokeColor(NSColor.gridColor.withAlphaComponent(0.55).cgColor)
        for x in stride(from: -0.5, through: 1.5, by: 0.5) {
            let p = point(x: x, y: 0)
            context.move(to: CGPoint(x: p.x, y: plot.minY))
            context.addLine(to: CGPoint(x: p.x, y: plot.maxY))
        }
        for fraction in [-1.0, -0.5, 0.0, 0.5, 1.0] {
            let p = point(x: 0, y: fraction * magnitude)
            context.move(to: CGPoint(x: plot.minX, y: p.y))
            context.addLine(to: CGPoint(x: plot.maxX, y: p.y))
        }
        context.strokePath()

        context.restoreGState()

        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: plot, xRadius: 4, yRadius: 4).stroke()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for x in stride(from: -0.5, through: 1.5, by: 0.5) {
            let text = String(format: "%.1f", x) as NSString
            let size = text.size(withAttributes: labelAttributes)
            let p = point(x: x, y: 0)
            text.draw(at: CGPoint(x: p.x - size.width / 2, y: plot.minY - size.height - 4),
                      withAttributes: labelAttributes)
        }
        for y in [-magnitude, 0, magnitude] {
            let text = String(format: "%.3g", y) as NSString
            let size = text.size(withAttributes: labelAttributes)
            let p = point(x: 0, y: y)
            text.draw(at: CGPoint(x: plot.minX - size.width - 6, y: p.y - size.height / 2),
                      withAttributes: labelAttributes)
        }

        let axis = "Unit intervals" as NSString
        let axisSize = axis.size(withAttributes: labelAttributes)
        axis.draw(at: CGPoint(x: plot.midX - axisSize.width / 2, y: bounds.minY + 2),
                  withAttributes: labelAttributes)
    }

    private func cachedDensityImage(size: CGSize, magnitude: Double, xMin: Double, xMax: Double) -> CGImage? {
        let scale = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
        let width = max(Int((size.width * scale).rounded(.up)), 1)
        let height = max(Int((size.height * scale).rounded(.up)), 1)
        if let cachedDensity, cachedDensity.width == width, cachedDensity.height == height {
            return cachedDensity.image
        }
        guard let image = densityImage(width: width, height: height, scale: scale,
                                       magnitude: magnitude, xMin: xMin, xMax: xMax) else { return nil }
        cachedDensity = (image, width, height)
        return image
    }

    private func densityImage(width: Int, height: Int, scale: CGFloat,
                              magnitude: Double, xMin: Double, xMax: Double) -> CGImage? {
        var grayscale = [UInt8](repeating: 0, count: width * height)

        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let grayContext = CGContext(data: &grayscale, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: graySpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        grayContext.setShouldAntialias(true)
        grayContext.setAllowsAntialiasing(true)
        grayContext.setLineWidth(3 * scale)
        grayContext.setLineCap(.round)
        grayContext.setLineJoin(.round)
        // Each trace contributes an equal share of the finished density. A fixed opacity makes a
        // larger capture look artificially brighter (and quickly hides the less common paths),
        // whereas 1/n keeps the image normalized as the number of folded traces changes.
        let traceOpacity = 1 / CGFloat(traces.count)
        grayContext.setStrokeColor(CGColor(gray: 1, alpha: traceOpacity))

        func densityPoint(x: Double, y: Double) -> CGPoint {
            CGPoint(x: CGFloat((x - xMin) / (xMax - xMin)) * CGFloat(width),
                    y: (0.5 + CGFloat(y / magnitude) * 0.5) * CGFloat(height))
        }
        for trace in traces {
            grayContext.beginPath()
            var started = false
            for index in timeUI.indices {
                guard trace[index].isFinite else {
                    started = false
                    continue
                }
                let sample = densityPoint(x: timeUI[index], y: trace[index])
                if started { grayContext.addLine(to: sample) } else { grayContext.move(to: sample); started = true }
            }
            grayContext.strokePath()
        }

        // With one trace contributing 1/n, even the most frequently occupied pixels generally use
        // only a small part of the byte range. Stretch the completed density image to 0...1 before
        // applying the colour ramp so the strongest path always reaches the top of the palette,
        // while preserving every lesser path's density relative to it.
        let peakDensity = grayscale.max() ?? 0
        let densityScale = peakDensity > 0 ? 1 / Float(peakDensity) : 0
        var rgba = EyeDensityColorizer.shared?.colorize(grayscale, densityScale: densityScale)
            ?? Self.colorizeOnCPU(grayscale, densityScale: densityScale)
        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        guard let colorContext = CGContext(data: &rgba, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: rgbSpace,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return colorContext.makeImage()
    }

    /// Fallback for when no Metal device is available; produces the same premultiplied RGBA8 as
    /// EyeDensityColorize.metal.
    private static func colorizeOnCPU(_ grayscale: [UInt8], densityScale: Float) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: grayscale.count * 4)
        for pixel in grayscale.indices {
            let color = EnergyColorMap.rgba(at: CGFloat(Float(grayscale[pixel]) * densityScale))
            let offset = pixel * 4
            // premultipliedLast is Core Graphics' native compositing format. Premultiplying here
            // keeps the low-alpha end free from coloured fringes when drawn over the chart grid.
            rgba[offset] = UInt8((color.red * color.alpha * 255).rounded())
            rgba[offset + 1] = UInt8((color.green * color.alpha * 255).rounded())
            rgba[offset + 2] = UInt8((color.blue * color.alpha * 255).rounded())
            rgba[offset + 3] = UInt8((color.alpha * 255).rounded())
        }
        return rgba
    }
}

/// Runs EyeDensityColorize.metal: the per-pixel EnergyColorMap lookup that dominated eye-diagram
/// drawing time on the CPU. nil when Metal (or the framework's compiled shader) is unavailable.
private final class EyeDensityColorizer {
    static let shared = EyeDensityColorizer()

    /// Texel count of the colour-ramp texture; the kernel filters linearly between texels, so this
    /// only needs to resolve EnergyColorMap's piecewise-linear stops, not every density level.
    private static let rampWidth = 1024

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let ramp: MTLTexture

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: EyeDiagramView.self)),
              let function = library.makeFunction(name: "colorizeEyeDensity"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = Self.rampWidth
        descriptor.usage = .shaderRead
        guard let ramp = device.makeTexture(descriptor: descriptor) else { return nil }
        var texels = [Float](repeating: 1, count: Self.rampWidth * 4)
        for index in 0..<Self.rampWidth {
            let rgb = EnergyColorMap.rgb(at: CGFloat(index) / CGFloat(Self.rampWidth - 1))
            texels[index * 4] = Float(rgb.red)
            texels[index * 4 + 1] = Float(rgb.green)
            texels[index * 4 + 2] = Float(rgb.blue)
        }
        ramp.replace(region: MTLRegionMake1D(0, Self.rampWidth), mipmapLevel: 0,
                     withBytes: texels, bytesPerRow: Self.rampWidth * 4 * MemoryLayout<Float>.size)
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.ramp = ramp
    }

    /// Premultiplied RGBA8 for `grayscale`, or nil if the GPU work could not be set up/completed.
    func colorize(_ grayscale: [UInt8], densityScale: Float) -> [UInt8]? {
        let pixelCount = grayscale.count
        guard pixelCount > 0,
              let input = grayscale.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: pixelCount, options: .storageModeShared)
              }),
              let output = device.makeBuffer(length: pixelCount * 4, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        var scale = densityScale
        var count = UInt32(pixelCount)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&scale, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.setTexture(ramp, index: 0)
        let threadsPerGroup = MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
        encoder.dispatchThreads(MTLSize(width: pixelCount, height: 1, depth: 1),
                                threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return [UInt8](UnsafeRawBufferPointer(start: output.contents(), count: pixelCount * 4))
    }
}
