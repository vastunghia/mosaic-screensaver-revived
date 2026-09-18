// APP side of spike 2.
//
// It has to be a real signed .app launched with `open`: run it from a shell and TCC
// attributes the access to the Terminal, making the answer false. It is the central
// methodological point of this spike.

import AppKit

let marker = "spike2-app-\(Int(Date().timeIntervalSince1970))"
let home = realHomeDirectory()

say("SPIKE2 ===== APP side =====")
say("SPIKE2 app    pid=\(ProcessInfo.processInfo.processIdentifier) home=\(home)")
say("SPIKE2 app    sandbox=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "(none)")")
say("SPIKE2 app    marker=\(marker)")

for c in candidates(realHome: home) {
    let (outcome, detail) = tryWrite(dir: c.dir, fileName: "app-marker.txt", content: marker)
    say(line("app", c.name, "write", outcome, detail))
}

say("SPIKE2 app    done — now select PathProbe in System Settings")

// An app launched with `open` has to quit by itself, without showing any window.
exit(0)
