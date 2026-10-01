// Control experiment: loads Spike4Launcher.saver in an ordinary process, outside the
// legacyScreenSaver sandbox, so "the saver cannot launch apps" is not confused with
// "the launch code is wrong". Not part of the product.

import AppKit
import ScreenSaver

let saverPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSHomeDirectory() + "/Library/Screen Savers/Spike4Launcher.saver"

guard let bundle = Bundle(path: saverPath), bundle.load(),
      let cls = bundle.principalClass as? ScreenSaverView.Type else {
    print("HOST: cannot load \(saverPath)"); exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let rect = NSRect(x: 0, y: 0, width: 640, height: 360)
guard let view = cls.init(frame: rect, isPreview: false) else {
    print("HOST: init returned nil"); exit(1)
}
let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Spike 4 — control, outside the sandbox"
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)
view.startAnimation()
Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in exit(0) }
app.run()
