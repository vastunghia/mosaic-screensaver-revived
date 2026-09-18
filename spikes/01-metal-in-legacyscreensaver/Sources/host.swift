// Control experiment: loads MetalSpike.saver in an ordinary window, outside the
// legacyScreenSaver sandbox. It serves to separate "the Metal code is wrong" from "the
// screen saver environment forbids it". Not part of the product.

import AppKit
import ScreenSaver

let saverPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSHomeDirectory() + "/Library/Screen Savers/MetalSpike.saver"

guard let bundle = Bundle(path: saverPath) else {
    print("HOST: cannot open bundle: \(saverPath)"); exit(1)
}
guard bundle.load() else {
    print("HOST: bundle.load() failed"); exit(1)
}
guard let cls = bundle.principalClass as? ScreenSaverView.Type else {
    print("HOST: principalClass is not a ScreenSaverView: \(String(describing: bundle.principalClass))")
    exit(1)
}
print("HOST: principalClass = \(cls)")

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let rect = NSRect(x: 0, y: 0, width: 960, height: 540)
guard let view = cls.init(frame: rect, isPreview: false) else {
    print("HOST: init(frame:isPreview:) returned nil"); exit(1)
}

let window = NSWindow(contentRect: rect,
                      styleMask: [.titled, .closable],
                      backing: .buffered,
                      defer: false)
window.title = "Metal spike — control, outside the sandbox"
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

view.startAnimation()
print("HOST: animation started, closing in 8 seconds")

DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
    view.stopAnimation()
    print("HOST: done")
    app.terminate(nil)
}

app.run()
