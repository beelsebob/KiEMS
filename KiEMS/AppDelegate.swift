import Cocoa

// No Storyboard/XIB: the whole app (main menu included) is built programmatically, matching this
// project's preference for plain, inspectable source over Interface Builder files.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Lazily created on first "Jobs…" selection, then kept alive (shown/hidden, never deallocated)
    // for the app's whole lifetime -- see JobsWindowController's own doc comment for why it's owned
    // here rather than by any one Document/DocumentWindowController.
    private var jobsWindowController: JobsWindowController?

    /// KiCad's runtime, created in main.swift before anything can query a board. Every Document's
    /// boards and pipelines hold it too.
    let kicadRuntime: KicadRuntime

    init(kicadRuntime: KicadRuntime) {
        self.kicadRuntime = kicadRuntime
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Document.removeStaleScratchDirectories()
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About KiEMS",
                         action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit KiEMS", action: #selector(NSApplication.terminate(_:)),
                         keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)),
                         keyEquivalent: "o")

        // Unlike a NIB-built menu (where checking "Open Recent" in IB's menu item inspector wires
        // this up as a hidden, undocumented flag AppKit recognizes at load time), a programmatically
        // built submenu gets none of that for free -- confirmed empirically: NSDocumentController
        // does NOT auto-populate an arbitrary submenu just because it contains a
        // clearRecentDocuments: item. This controller rebuilds the submenu's contents itself, right
        // before it's shown (see menuNeedsUpdate(_:)), from NSDocumentController's own
        // recentDocumentURLs -- the underlying recent-documents *list* is still the system's, only
        // the menu presentation is hand-rolled.
        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let openRecentMenu = NSMenu(title: "Open Recent")
        openRecentMenu.delegate = self
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)

        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        fileMenu.addItem(NSMenuItem.separator())
        // No explicit target -- routed through the responder chain to the frontmost document
        // window's own DocumentWindowController, same as Close/Save above (see
        // DocumentWindowController.regenerateGeometry(_:)'s own doc comment for what this discards).
        fileMenu.addItem(withTitle: "Regenerate Geometry",
                         action: #selector(DocumentWindowController.regenerateGeometry(_:)), keyEquivalent: "")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                            keyEquivalent: "m")
        windowMenu.addItem(NSMenuItem.separator())
        let jobsItem = NSMenuItem(title: "Jobs", action: #selector(showJobsWindow), keyEquivalent: "j")
        jobsItem.target = self
        windowMenu.addItem(jobsItem)

        return mainMenu
    }

    @objc private func showJobsWindow() {
        let controller = jobsWindowController ?? JobsWindowController()
        jobsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                NSApp.presentError(error)
            }
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilds the "Open Recent" submenu right before it's shown, from
    /// NSDocumentController.recentDocumentURLs -- see buildMainMenu()'s own doc comment on why this
    /// has to be done by hand rather than relying on AppKit to do it automatically.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recentURLs = NSDocumentController.shared.recentDocumentURLs
        if recentURLs.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for url in recentURLs {
                let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent,
                                       action: #selector(openRecentDocument(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                item.image = NSWorkspace.shared.icon(forFile: url.path)
                menu.addItem(item)
            }
        }
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                    keyEquivalent: "")
        clearItem.target = NSDocumentController.shared
        menu.addItem(clearItem)
    }
}
