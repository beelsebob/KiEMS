import Cocoa
import Darwin

/// A simulation.json document, stored as a package directory (Finder shows it as one file, like
/// .xcodeproj) rather than a flat file: `simulation.json` today, plus `ems/` (geometry/simulation/
/// results) once the app can run simulations. The linked KiCad board is never copied in (see
/// EMSConfigBridge.kicadPcbPath) -- there's no `fab/` to pre-create, only simulation.json itself.
///
/// This manages `fileURL` as a real on-disk directory via the URL-based read/write overrides
/// (`read(from:ofType:)`/`write(to:ofType:)`), not the Data-based ones NSDocument defaults to --
/// libkiems does its own filesystem I/O (a future FDTD-worker subprocess writing into `ems/`
/// directly), which can't be represented as an in-memory `NSFileWrapper` tree that only gets
/// flushed to disk on save.
final class Document: NSDocument {
    private(set) var packageURL: URL?
    private(set) var config: EMSConfigBridge = .configWithDefaults()

    /// Where the geometry/simulation pipeline writes its fab/ems output -- see pipelineDirectory.
    /// Lives for this Document object's whole lifetime, saved or not: the pipeline (kicad-cli,
    /// kiems_fdtd_worker) never writes into the real package directly, only
    /// here, precisely so it never touches packageURL's files out from under an open document -- see
    /// pipelineDirectory's own doc comment for why that matters. migrateScratchDirectory copies this
    /// into the real package at save time, but doesn't discard it afterward: the *next* pipeline run
    /// still needs somewhere of its own to write, same as before the document was ever saved.
    private var scratchDirectory: URL?
    /// Held for exactly as long as scratchDirectory can still be used by this document or one of
    /// its finishing background jobs. A later KiEMS process can therefore distinguish abandoned
    /// temp directories left by a crash/forced Xcode stop from another live document's workspace.
    private var scratchLockFileDescriptor: Int32?

    private static let scratchDirectoryPrefix = "KiEMS-"
    private static let scratchLockFileName = ".active.lock"

    /// Removes only abandoned KiEMS scratch directories. `flock` is process-scoped and released by
    /// the kernel even after a crash, so successfully taking this non-blocking exclusive lock proves
    /// that no live KiEMS document still owns the directory. Legacy directories made before the
    /// lock file existed are handled too: opening the marker creates it, then the same lock test
    /// makes them collectable on the first launch of a fixed build.
    static func removeStaleScratchDirectories() {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory
        guard let children = try? fileManager.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for directory in children where directory.lastPathComponent.hasPrefix(scratchDirectoryPrefix) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let lockURL = directory.appendingPathComponent(scratchLockFileName)
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                try? fileManager.removeItem(at: directory)
                _ = flock(descriptor, LOCK_UN)
            }
            Darwin.close(descriptor)
        }
    }

    /// One EMSSimulationPipelineBridge per simulation, keyed by simulation name -- shared by
    /// GeometryViewController and SimulationResultsViewController so switching between a
    /// simulation's Geometry and Simulation Results rows never redoes work the other row already
    /// paid for (see EMSSimulationPipelineBridge.h's own doc comment). Keyed by name rather than
    /// index/identity because that's the pipeline's own natural key (SimulationConfig::name(),
    /// also how its on-disk output under pipelineDirectory is laid out) -- renaming a simulation
    /// starts it a fresh pipeline rather than carrying an old one's cache across, which matches its
    /// on-disk output becoming orphaned under the old name too.
    private var pipelines: [String: EMSSimulationPipelineBridge] = [:]

    /// The most recently requested board -- see board(at:).
    private var cachedBoard: KicadBoardBridge?

    override class var autosavesInPlace: Bool { false }

    private static var kicadRuntime: KicadRuntime {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            preconditionFailure("KiEMS documents require the app's AppDelegate")
        }
        return delegate.kicadRuntime
    }

    func pipeline(forSimulationNamed name: String) -> EMSSimulationPipelineBridge {
        if let existing = pipelines[name] {
            return existing
        }
        let pipeline = EMSSimulationPipelineBridge(simulationName: name, runtime: Self.kicadRuntime)
        pipelines[name] = pipeline
        return pipeline
    }

    /// The KiCad board config.kicadPcbPath links to, or nil before one is linked. See board(at:).
    var board: KicadBoardBridge? {
        config.kicadPcbPath.map(board(at:))
    }

    /// The board at `kicadPcbPath`, owned by this document so every view of it shares one parsed
    /// board (reparsed only when its files change on disk) and it's released with the document.
    /// Main thread only; the returned object itself is safe to query from any queue.
    func board(at kicadPcbPath: String) -> KicadBoardBridge {
        if let cachedBoard, cachedBoard.kicadPcbPath == kicadPcbPath {
            return cachedBoard
        }
        let board = KicadBoardBridge(runtime: Self.kicadRuntime, kicadPcbPath: kicadPcbPath)
        cachedBoard = board
        return board
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    override func read(from url: URL, ofType typeName: String) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw Self.error("\"\(url.lastPathComponent)\" isn't a KiEMS Simulation package.")
        }
        let configURL = url.appendingPathComponent("simulation.json")
        config = try EMSConfigBridge.config(withContentsOfFile: configURL.path)
        packageURL = url
    }

    override func write(to url: URL, ofType typeName: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let configURL = url.appendingPathComponent("simulation.json")
        try config.save(toFile: configURL.path)
        migrateScratchDirectory(into: url)
        packageURL = url
    }

    /// Where the geometry/simulation pipeline should write its fab/ems output: always a private
    /// per-document scratch directory under the system temp directory, created on first use --
    /// *never* packageURL directly, even once this document has been saved. The pipeline gets there
    /// via subprocesses (kicad-cli and kiems_fdtd_worker) that aren't
    /// NSDocument-aware; if one of them wrote straight into an already-saved package while it's
    /// still open, macOS's file-coordination layer sees an uncoordinated write from an unrelated
    /// process and flags the package as "modified by another application" the next time the user
    /// saves -- confusing, since nothing outside this app touched it. Writing to scratch instead and
    /// having *this process* (not a subprocess) copy the result into the package -- see
    /// migrateScratchDirectory, called from write(to:ofType:) -- keeps every real modification to the
    /// package attributable to this app's own coordinated save, so that warning never fires.
    /// GeometryViewController (and, eventually, whatever runs the simulate/postprocess steps) should
    /// always go through this rather than reading packageURL directly.
    var pipelineDirectory: URL {
        if let scratchDirectory {
            return scratchDirectory
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.scratchDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let lockURL = scratch.appendingPathComponent(Self.scratchLockFileName)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            scratchLockFileDescriptor = descriptor
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        // A reopened package may already contain completed geometry, simulation CSVs, and lazy
        // field-frame files. Seed the private working copy with them before the pipeline first
        // examines it; otherwise every bridge starts against an empty directory and necessarily
        // treats all saved stages as cache misses. The scratch copy remains authoritative for this
        // open Document and is copied back by migrateScratchDirectory on the next save.
        if let packageURL {
            let fileManager = FileManager.default
            for subdirectory in ["fab", "ems"] {
                let source = packageURL.appendingPathComponent(subdirectory)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = scratch.appendingPathComponent(subdirectory)
                try? fileManager.copyItem(at: source, to: destination)
            }
        }
        scratchDirectory = scratch
        return scratch
    }

    /// Copies whatever fab/ems output the pipeline has written to the scratch directory (see
    /// pipelineDirectory) into the real package, so a save doesn't strand or throw away pipeline
    /// work already done -- e.g. a geometry step run since the last save. Called on every save, not
    /// just the first: pipelineDirectory always keeps using the same scratch directory for this
    /// Document's whole lifetime (never packageURL, saved or not -- see its own doc comment), so
    /// later runs after an initial save still need this same migration on the *next* save too.
    /// Best-effort: pipeline output is always regenerable by re-running the step, so a copy failure
    /// here isn't worth failing the save over. A no-op if the pipeline hasn't run yet this session
    /// (no scratchDirectory) or nothing's been written to it (fab/ems don't exist there).
    private func migrateScratchDirectory(into url: URL) {
        guard let scratchDirectory, scratchDirectory != url else { return }
        let fileManager = FileManager.default
        for subdirectory in ["fab", "ems"] {
            let source = scratchDirectory.appendingPathComponent(subdirectory)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = url.appendingPathComponent(subdirectory)
            try? fileManager.removeItem(at: destination)
            try? fileManager.copyItem(at: source, to: destination)
        }
    }

    // Cancels/drops this document's own jobs before the standard close teardown -- otherwise a
    // still-running job would keep referencing (via Job's own weak `document`) a Document that's
    // about to go away, and its GPU work would keep running for no one to ever see the result of.
    override func close() {
        JobScheduler.shared.cancelAll(for: self)
        super.close()
    }

    deinit {
        // Not a direct removeItem() here -- close() (above) only *requests* cancellation of any
        // running job for this document; the job's own background call can still be genuinely
        // in-flight (specifically, inside openEMS's own uninterruptible SetupFDTD()) well after this
        // Document deallocates. Deleting the directory a still-running background thread is chdir'd
        // into crashes it the moment it next asks for its own cwd -- see cleanUpDirectory(_:)'s own
        // doc comment for the full story and why routing through JobScheduler's serial queue fixes it.
        if let scratchDirectory {
            JobScheduler.shared.cleanUpDirectory(
                scratchDirectory, lockFileDescriptor: scratchLockFileDescriptor)
            scratchLockFileDescriptor = nil
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "KiEMS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
