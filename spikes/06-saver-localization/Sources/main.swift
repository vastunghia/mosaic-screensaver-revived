// Spike 6 — the control: the same probe, outside any sandbox, on the same bundle.
//   build/locale-control build/LocaleProbe.saver
//   build/locale-control build/LocaleProbe.saver -AppleLanguages '(en)'

import Foundation

guard CommandLine.arguments.count > 1, let bundle = Bundle(path: CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: locale-control <path to .saver>\n".data(using: .utf8)!)
    exit(2)
}
for line in Probe.run(bundle: bundle) {
    print(line)
}
