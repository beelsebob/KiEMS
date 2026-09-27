import Cocoa

let app = NSApplication.shared
// KiCad and wxWidgets own process-global state whose initialization touches Cocoa. Do this on the
// main thread before any document controller can dispatch a board query to a worker queue. Board
// parsing itself remains asynchronous.
do {
    try KicadBoardBridge.prepareRuntime()
} catch {
    NSLog("Unable to initialize the KiCad runtime: \(error.localizedDescription)")
}
// KiEMS's board/field visualizations and inspector palette are designed as a single dark workspace.
// Set the application appearance before any menus or windows are constructed so every descendant
// inherits Dark Aqua regardless of the user's system appearance or automatic day/night switching.
app.appearance = NSAppearance(named: .darkAqua)
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

