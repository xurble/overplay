import Testing
@testable import Overplay

@Suite("Made For You")
struct MadeForYouTests {
    @Test func catalogPlaylistsAreReadLiveAndLibraryPlaylistsAreNot() {
        #expect(AppleMusicPlaylistSourceSync.isCatalogPlaylistID("pl.pm-20e9f373919da0806a0c5e49b1cca2c0"))
        #expect(AppleMusicPlaylistSourceSync.isCatalogPlaylistID("pl.u-WabZzGahdJJLlA"))
        #expect(!AppleMusicPlaylistSourceSync.isCatalogPlaylistID("p.eoGxL6oTkVVDqL"))
    }

    @Test func aMixIsAnOrdinarySourceAndCollection() {
        let item = MadeForYouLibrary.Item(id: "pl.pm-1", name: "New Music")
        #expect(item.sourcePlaylist == AppleMusicPlaylist(id: "pl.pm-1", name: "New Music", trackCount: nil))
        #expect(item.collection.kind == .madeForYou)
        #expect(item.collection.groupKey == "madeForYou:pl.pm-1")
        #expect(item.collection.contextTitle == "New Music")
    }
}
