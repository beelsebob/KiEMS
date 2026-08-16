import Foundation

/// Watches a single file path for content or existence changes, transparently re-arming itself
/// after an atomic "write a new file, rename it over the original" save -- the pattern KiCad (and
/// most well-behaved editors) use. A `.delete`/`.rename` event on the watched descriptor means
/// *that inode* just got replaced, not that the file is gone for good: closing and reopening the
/// same path picks up whatever got renamed into place.
private final class SelfRepairingFileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init?(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        guard arm() else { return nil }
    }

    @discardableResult
    private func arm() -> Bool {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let data = newSource.data
            onChange()
            if data.contains(.delete) || data.contains(.rename) {
                newSource.cancel()
                // A brief delay before reopening the same path -- reopening immediately can race the
                // writer's rename and miss the new inode entirely.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.arm() }
            }
        }
        newSource.setCancelHandler { close(fd) }
        newSource.resume()
        source = newSource
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}

/// Watches a linked KiCad board's `.kicad_pcb` (and, if found, its sibling `.kicad_pro` project
/// file) for changes made outside this app -- typically the user editing/saving the board in KiCad
/// itself while this document is open. Coalesces bursts of near-simultaneous filesystem activity
/// (KiCad's save touches more than just the board file) into a single debounced callback.
final class KicadFileWatcher {
    private var pcbWatcher: SelfRepairingFileWatcher?
    private var projectWatcher: SelfRepairingFileWatcher?
    private var debounceWorkItem: DispatchWorkItem?

    /// Called on the main queue, debounced, whenever the watched board or project file changes.
    var onChange: (() -> Void)?

    /// Replaces whatever this was watching before -- safe to call every time the linked board
    /// changes, including to the same path again (e.g. reopening a document).
    func startWatching(pcbPath: String, projectPath: String?) {
        stopWatching()
        pcbWatcher = SelfRepairingFileWatcher(path: pcbPath) { [weak self] in self?.scheduleReload() }
        if let projectPath {
            projectWatcher = SelfRepairingFileWatcher(path: projectPath) { [weak self] in self?.scheduleReload() }
        }
    }

    func stopWatching() {
        pcbWatcher?.stop()
        pcbWatcher = nil
        projectWatcher?.stop()
        projectWatcher = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    private func scheduleReload() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.onChange?() }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    deinit { stopWatching() }
}
