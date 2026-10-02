import CoreGraphics
import Testing
@testable import MosaicPhotos

@Suite("Face-aware crop")
struct FaceAwareCropTests {
    // 900x1600 portrait: the window is 900x506, free to slide 1094 px down,
    // and centred at y = 547.

    @Test("without faces it is the centre crop")
    func noFacesIsTheCentre() {
        let choice = FaceAwareCrop.choose(width: 900, height: 1600, faces: [])
        #expect(choice.rect == CanonicalCrop.rect(width: 900, height: 1600))
        #expect(choice.shift == 0)
        #expect(choice.cut == 0 && choice.centreCut == 0)
    }

    @Test("a face already inside the centre window does not move it")
    func faceInsideKeepsTheCentre() {
        let choice = FaceAwareCrop.choose(
            width: 900, height: 1600, faces: [CGRect(x: 300, y: 700, width: 200, height: 200)]
        )
        #expect(choice.shift == 0)
        #expect(choice.cut == 0)
    }

    @Test("a face cut by the centre pulls the window just far enough to keep it")
    func faceAboveMovesTheWindowUpTheLeastNeeded() {
        let choice = FaceAwareCrop.choose(
            width: 900, height: 1600, faces: [CGRect(x: 300, y: 400, width: 200, height: 200)]
        )
        #expect(choice.centreCut == 1)
        #expect(choice.cut == 0)
        // The top of the head — half a face above the face — and not a pixel
        // further.
        #expect(choice.rect.minY == 300)
        #expect(choice.shift == 300 - 547)
        #expect(choice.rect.size == CanonicalCrop.rect(width: 900, height: 1600).size)
    }

    @Test("most faces win over the nearest face")
    func countBeatsDistance() {
        let faces = [
            CGRect(x: 100, y: 1000, width: 100, height: 100),   // a little below the centre window
            CGRect(x: 100, y: 100, width: 100, height: 100),    // two far up
            CGRect(x: 500, y: 150, width: 100, height: 100),
        ]
        let choice = FaceAwareCrop.choose(width: 900, height: 1600, faces: faces)
        #expect(choice.cut == 1)
        #expect(choice.rect.minY == 50)
    }

    @Test("a face longer than the window is cut wherever it goes, and does not move it")
    func hugeFaceIsIgnored() {
        let choice = FaceAwareCrop.choose(
            width: 900, height: 1600, faces: [CGRect(x: 100, y: 100, width: 700, height: 700)]
        )
        #expect(choice.shift == 0)
        #expect(choice.cut == 1 && choice.centreCut == 1)
    }

    @Test("a face the photograph's frame already cuts does not count")
    func faceCutByTheFrameIsIgnored() {
        // Half a child at the bottom edge (193C3333 (1)): moving down for it
        // would take the hat off the subject at the top.
        let faces = [
            CGRect(x: 300, y: 1450, width: 200, height: 150),   // off the bottom
            CGRect(x: 300, y: 300, width: 100, height: 100),    // whole with its head only from 250
        ]
        let choice = FaceAwareCrop.choose(width: 900, height: 1600, faces: faces)
        #expect(choice.cut == 0 && choice.centreCut == 1, "the edge face is not counted either way")
        #expect(choice.rect.minY == 250)
        #expect(FaceAwareCrop.isCutByFrame(faces[0], width: 900, height: 1600))
        #expect(!FaceAwareCrop.isCutByFrame(faces[1], width: 900, height: 1600))

        // Alone, it leaves the window where it is.
        let alone = FaceAwareCrop.choose(width: 900, height: 1600, faces: [faces[0]])
        #expect(alone.shift == 0)
    }

    @Test("a wide panorama slides sideways")
    func panoramaSlidesHorizontally() {
        let choice = FaceAwareCrop.choose(
            width: 4000, height: 1000, faces: [CGRect(x: 3700, y: 400, width: 200, height: 200)]
        )
        #expect(choice.rect.height == 1000)
        #expect(choice.rect.maxX >= 3900)
        #expect(choice.rect.maxX == 3900)
        #expect(choice.cut == 0)
    }

    @Test("a 16:9 photograph has nowhere to go")
    func exactAspectNeverMoves() {
        let choice = FaceAwareCrop.choose(
            width: 1920, height: 1080, faces: [CGRect(x: 10, y: 10, width: 100, height: 100)]
        )
        #expect(choice.rect == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(choice.slack == 0 && choice.cut == 0)
    }

    @Test("between two equally good places, the one nearer the centre")
    func tieGoesToTheCentre() {
        // One face near the top, one near the bottom: either can be kept, not
        // both. The bottom one needs a shorter move.
        let faces = [
            CGRect(x: 100, y: 50, width: 100, height: 100),
            CGRect(x: 100, y: 1200, width: 100, height: 100),
        ]
        let choice = FaceAwareCrop.choose(width: 900, height: 1600, faces: faces)
        #expect(choice.cut == 1)
        #expect(choice.rect.maxY == 1300)
    }

    @Test("between as many faces, the bigger one wins over the nearer one")
    func areaBeatsDistance() {
        // The doll and the person holding it (193C3952): the small face is
        // nearer the centre, the big one is the subject.
        let faces = [
            CGRect(x: 100, y: 100, width: 300, height: 300),    // big, far up
            CGRect(x: 500, y: 1000, width: 100, height: 100),   // small, just below the centre
        ]
        let choice = FaceAwareCrop.choose(width: 900, height: 1600, faces: faces)
        #expect(choice.cut == 1)
        #expect(choice.rect.minY == 0)
        #expect(choice.rect.maxY >= 400)
    }

    @Test("the head goes with the face, unless only the face fits")
    func headroomGivesWayToTheFace() {
        // 400 tall: with its head, 600, more than the 506 window.
        let choice = FaceAwareCrop.choose(
            width: 900, height: 1600, faces: [CGRect(x: 200, y: 1100, width: 400, height: 400)]
        )
        #expect(choice.cut == 0)
        #expect(choice.rect.maxY == 1500)
        #expect(FaceAwareCrop.head(of: CGRect(x: 0, y: 100, width: 40, height: 40))
                == CGRect(x: 0, y: 80, width: 40, height: 60))
    }
}
