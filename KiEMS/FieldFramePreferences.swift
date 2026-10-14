import Foundation

/// How simulations store their field frames for the Field Viewer -- chosen in the Settings window,
/// kept in the user's defaults, and handed to each simulation's pipeline as its run starts (see
/// JobScheduler.execute), so a change applies to the next run, not to frames already stored.
enum FieldFramePreferences {
    static let defaultIntervalSteps = 1000

    private static let precisionKey = "FieldFramePrecision"
    private static let channelsKey = "FieldFrameChannels"
    private static let intervalKey = "FieldFrameIntervalSteps"
    private static let directoryKey = "FieldFrameDirectory"

    // Saved by name rather than raw value, so reordering the enums can't change a saved choice.
    private static let precisionNames: [(EMSFieldFramePrecision, String)] = [
        (.int8, "int8"), (.int12, "int12"), (.float16, "float16"), (.float32, "float32"),
    ]
    private static let channelNames: [(EMSFieldFrameChannels, String)] = [
        (.allComponents, "components"), (.energy, "energy"),
    ]

    static var precision: EMSFieldFramePrecision {
        get {
            let name = UserDefaults.standard.string(forKey: precisionKey)
            return precisionNames.first { $0.1 == name }?.0 ?? .float32
        }
        set {
            UserDefaults.standard.set(precisionNames.first { $0.0 == newValue }?.1, forKey: precisionKey)
        }
    }

    static var channels: EMSFieldFrameChannels {
        get {
            let name = UserDefaults.standard.string(forKey: channelsKey)
            return channelNames.first { $0.1 == name }?.0 ?? .allComponents
        }
        set {
            UserDefaults.standard.set(channelNames.first { $0.0 == newValue }?.1, forKey: channelsKey)
        }
    }

    /// Timesteps between stored frames; the first and last steps are always stored too.
    static var intervalSteps: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: intervalKey)
            return stored > 0 ? stored : defaultIntervalSteps
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: intervalKey) }
    }

    /// Where field frames are written, as `<document> - <simulation>.kemsf` packages; nil keeps
    /// them in the document file itself ("In File", the default).
    static var directory: URL? {
        get { UserDefaults.standard.string(forKey: directoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: directoryKey) }
    }

    static func apply(to pipeline: EMSSimulationPipelineBridge, documentName: String, simulationName: String) {
        pipeline.fieldFramePrecision = precision
        pipeline.fieldFrameChannels = channels
        pipeline.fieldFrameIntervalSteps = UInt(intervalSteps)
        pipeline.fieldFrameDirectory = directory?.path
        pipeline.fieldFrameSeriesName = "\(documentName) - \(simulationName)"
    }
}
