import Foundation

/// What this machine has been measured to spend per FDTD timestep on core and boundary cells (see
/// EMSGridStatistics), learned from real runs and kept in the user defaults so a later geometry can
/// be given a step-time and run-time prediction before it's ever simulated.
///
/// A step's wall time is modelled as `coreCells * coreSeconds + boundaryCells * boundarySeconds`,
/// fitted by least squares over every measurement window recorded so far. Each new run decays
/// everything recorded before it, so the fit follows hardware or engine changes rather than
/// averaging over them forever. Until the recorded grids differ enough in their core/boundary mix to separate the two
/// costs, both are taken to be the single per-cell cost that best fits.
final class StepTimingModel {
    static let shared = StepTimingModel()

    struct Rates {
        let coreSecondsPerCell: Double
        let boundarySecondsPerCell: Double

        func secondsPerStep(coreCells: Int64, boundaryCells: Int64) -> Double {
            Double(coreCells) * coreSecondsPerCell + Double(boundaryCells) * boundarySecondsPerCell
        }
    }

    /// Normal-equation sums for the two-parameter fit: c = core cells, b = boundary cells,
    /// t = seconds per step.
    private struct Sums: Codable {
        var cc = 0.0, cb = 0.0, bb = 0.0, ct = 0.0, bt = 0.0
    }

    private static let defaultsKey = "StepTimingModel.sums"
    /// Weight earlier runs keep each time a new one begins.
    private static let decay = 0.8
    private let defaults: UserDefaults
    private var sums: Sums

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Sums.self, from: data) {
            sums = stored
        } else {
            sums = Sums()
        }
    }

    /// Called once as each FDTD pass starts.
    func beginRun() {
        sums.cc *= Self.decay
        sums.cb *= Self.decay
        sums.bb *= Self.decay
        sums.ct *= Self.decay
        sums.bt *= Self.decay
        save()
    }

    /// Records one measurement window: `steps` timesteps of a grid with the given cell counts took
    /// `seconds` of wall time.
    func record(coreCells: Int64, boundaryCells: Int64, steps: Int, seconds: Double) {
        guard steps > 0, seconds > 0, coreCells + boundaryCells > 0 else { return }
        let c = Double(coreCells), b = Double(boundaryCells), t = seconds / Double(steps)
        // Weighted by step count, so a long window outweighs a short one.
        let w = Double(steps)
        sums.cc += w * c * c
        sums.cb += w * c * b
        sums.bb += w * b * b
        sums.ct += w * c * t
        sums.bt += w * b * t
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sums) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The fitted per-cell costs, or nil if nothing has been recorded yet.
    var rates: Rates? {
        let s = sums
        guard s.cc + s.bb > 0 else { return nil }
        let det = s.cc * s.bb - s.cb * s.cb
        // Relative to the product it's computed from: near zero means every recorded grid had
        // (nearly) the same core/boundary mix, so the two costs can't be told apart.
        if det > 1e-6 * s.cc * s.bb {
            let core = (s.ct * s.bb - s.bt * s.cb) / det
            let boundary = (s.bt * s.cc - s.ct * s.cb) / det
            if core > 0, boundary > 0 {
                return Rates(coreSecondsPerCell: core, boundarySecondsPerCell: boundary)
            }
        }
        // Single shared cost: minimise sum w * (t - k (c + b))^2.
        let k = (s.ct + s.bt) / (s.cc + 2 * s.cb + s.bb)
        guard k > 0, k.isFinite else { return nil }
        return Rates(coreSecondsPerCell: k, boundarySecondsPerCell: k)
    }
}

/// Wording shared by the Geometry and Simulation Results screens.
enum StepTimingFormat {
    static func cellCount(_ count: Int64) -> String {
        count.formatted(.number)
    }

    static func stepDuration(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(format: "%.1f ms", seconds * 1000)
        }
        return String(format: "%.2f s", seconds)
    }

    /// Cells per second, e.g. "512 Mcells/s".
    static func throughput(secondsPerCell: Double) -> String {
        let cellsPerSecond = 1 / secondsPerCell
        if cellsPerSecond >= 1e9 { return String(format: "%.2f Gcells/s", cellsPerSecond / 1e9) }
        if cellsPerSecond >= 1e6 { return String(format: "%.0f Mcells/s", cellsPerSecond / 1e6) }
        return String(format: "%.0f kcells/s", cellsPerSecond / 1e3)
    }

    private static let runFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func runDuration(_ seconds: Double) -> String {
        runFormatter.string(from: max(seconds, 1)) ?? "—"
    }
}
