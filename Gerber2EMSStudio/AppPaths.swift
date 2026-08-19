import Foundation

/// Helper-binary path resolution for the app bundle -- the Swift-side equivalent of
/// geber2ems/main.cpp's executableDir()/resolveKicadCli(), since this app has its own bundle
/// layout (Contents/MacOS/) rather than the CLI's flat BUILT_PRODUCTS_DIR.
enum AppPaths {
    /// Bundled alongside this app's own executable by the "Embed Helper Tools" build phase --
    /// never resolved via $PATH, matching every other helper-tool path in this project.
    static var kicadQueryHelperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/libkicad_smoketest").path
    }

    /// macOS's KiCad.app doesn't symlink kicad-cli anywhere on a typical PATH -- it ships only
    /// inside the app bundle. Mirrors main.cpp's resolveKicadCli(): scan $PATH first, then fall
    /// back to KiCad.app's own known location, then just hand back "kicad-cli" and let posix_spawnp
    /// itself report "not found" if even that fails.
    static func resolveKicadCli() -> String {
        let fileManager = FileManager.default
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("kicad-cli")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return "kicad-cli"
                }
            }
        }
        let fallback = "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
        if fileManager.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return "kicad-cli"
    }
}
