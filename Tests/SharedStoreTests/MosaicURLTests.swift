import Foundation
import Testing
@testable import SharedStore

/// The URL is the only thing the .saver can tell the app (spike 4), so both
/// sides have to read it the same way.
@Suite("Mosaic URL")
struct MosaicURLTests {
    @Test("every call survives the trip through a URL")
    func roundTrip() {
        for call in [MosaicURL.open, .update(reason: "index-missing"), .update(reason: "too few & stale = yes")] {
            #expect(MosaicURL(call.url) == call)
        }
        #expect(MosaicURL.update(reason: "index-missing").url.absoluteString == "mosaic://update?reason=index-missing")
    }

    @Test("anything that is not one of ours is refused")
    func foreign() {
        for text in ["mosaic://delete", "mosaic:", "https://open", "file:///open"] {
            #expect(MosaicURL(URL(string: text)!) == nil, "\(text)")
        }
    }

    @Test("an update without a reason is still an update")
    func noReason() {
        #expect(MosaicURL(URL(string: "MOSAIC://Update")!) == .update(reason: "unspecified"))
    }
}
