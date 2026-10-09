import MosaicPhotoKit
import Testing

/// Choosing albums and folders. The tree mirrors a sidebar:
///
///     Favorites
///     Travel/
///         2019/
///             Rome
///             Paris
///         Lisbon
///     Family
struct AlbumTreeTests {
    private let tree = AlbumTree(roots: [
        .favorites(id: "fav", title: "Favorites", count: 10),
        .folder(id: "travel", title: "Travel", children: [
            .folder(id: "2019", title: "2019", children: [
                .album(id: "rome", title: "Rome", count: 3),
                .album(id: "paris", title: "Paris", count: 4),
            ]),
            .album(id: "lisbon", title: "Lisbon", count: 5),
        ]),
        .album(id: "family", title: "Family", count: 6),
    ])

    @Test func aFolderCountsWhatItHolds() {
        #expect(tree.node("2019")?.count == 7)
        #expect(tree.node("travel")?.count == 12)
    }

    @Test func takingVideosOutAddsFoldersUpAgain() {
        let refined = tree.excludingVideos(["paris": 1, "lisbon": 2, "fav": 3, "gone": 9])
        #expect(refined.node("paris")?.count == 3)
        #expect(refined.node("2019")?.count == 6)
        #expect(refined.node("travel")?.count == 9)
        #expect(refined.node("fav")?.count == 7)
        #expect(refined.node("family")?.count == 6)
        #expect(refined.ordered(["travel", "family"]) == ["travel", "family"])
    }

    @Test func albumsAreListedInSidebarOrder() {
        #expect(tree.albums.map(\.id) == ["fav", "rome", "paris", "lisbon", "family"])
    }

    @Test func aChosenFolderTurnsOnEverythingInIt() {
        let chosen: Set = ["travel"]
        #expect(tree.state(of: "travel", in: chosen) == .on)
        #expect(tree.state(of: "2019", in: chosen) == .on)
        #expect(tree.state(of: "rome", in: chosen) == .on)
        #expect(tree.state(of: "family", in: chosen) == .off)
    }

    @Test func partOfAFolderMakesItMixed() {
        let chosen: Set = ["rome"]
        #expect(tree.state(of: "2019", in: chosen) == .mixed)
        #expect(tree.state(of: "travel", in: chosen) == .mixed)
        #expect(tree.state(of: "paris", in: chosen) == .off)
    }

    @Test func everythingInAFolderShowsItOnWithoutChoosingIt() {
        let chosen: Set = ["rome", "paris"]
        #expect(tree.state(of: "2019", in: chosen) == .on)
        #expect(tree.state(of: "travel", in: chosen) == .mixed)
        // Still the two albums: an album added to 2019 later stays out.
        #expect(tree.ordered(chosen) == ["rome", "paris"])
    }

    @Test func choosingAFolderAbsorbsWhatWasChosenInIt() {
        let chosen = tree.toggling("travel", in: ["rome", "lisbon", "family"])
        #expect(chosen == ["travel", "family"])
    }

    @Test func choosingAMixedFolderChoosesTheFolder() {
        #expect(tree.toggling("2019", in: ["rome"]) == ["2019"])
    }

    @Test func unchoosingSomethingInAChosenFolderKeepsTheRestOfIt() {
        let chosen = tree.toggling("rome", in: ["travel", "family"])
        #expect(chosen == ["paris", "lisbon", "family"])
        #expect(tree.state(of: "travel", in: chosen) == .mixed)
    }

    @Test func unchoosingASubfolderKeepsItsSiblings() {
        #expect(tree.toggling("2019", in: ["travel"]) == ["lisbon"])
    }

    @Test func unchoosingAFolderDropsWhatWasChosenInIt() {
        #expect(tree.toggling("travel", in: ["travel"]) == [])
        #expect(tree.toggling("2019", in: ["rome", "paris", "family"]) == ["family"])
    }

    @Test func togglingAnAlbumTwiceLeavesTheChoiceAsItWas() {
        let once = tree.toggling("family", in: ["rome"])
        #expect(once == ["rome", "family"])
        #expect(tree.toggling("family", in: once) == ["rome"])
    }

    @Test func theChoiceIsKeptInSidebarOrderWithoutStaleIdentifiers() {
        #expect(tree.ordered(["family", "gone", "travel"]) == ["travel", "family"])
        #expect(tree.titles(of: ["family", "gone", "2019"]) == ["2019", "Family"])
    }

    @Test func searchFindsFoldersAndAlbumsWithTheirPath() {
        let found = tree.search("r")
        #expect(found.map(\.id) == ["fav", "travel", "rome", "paris"])
        #expect(found.first { $0.id == "rome" }?.path == ["Travel", "2019"])
        #expect(found.first { $0.id == "travel" }?.path == [])
    }
}
