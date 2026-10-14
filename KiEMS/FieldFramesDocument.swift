import Cocoa

/// A `.kemsf` field-frame package opened on its own: plays its frames back over the board saved
/// with them, without the simulation document that wrote it. Read-only.
final class FieldFramesDocument: NSDocument {
    private var package: EMSFieldFramePackage?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        package = try EMSFieldFramePackage(url: url)
    }

    override func makeWindowControllers() {
        guard let package else { return }
        let viewer = FieldViewerViewController(package: package)
        let window = NSWindow(contentViewController: viewer)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.minSize = NSSize(width: 480, height: 360)
        let controller = NSWindowController(window: window)
        controller.windowFrameAutosaveName = "FieldFramesDocument"
        addWindowController(controller)
        window.center()
        viewer.setViewerVisible(true)
    }

}
