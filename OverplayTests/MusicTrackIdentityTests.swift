import Foundation
import Testing
@testable import Overplay

struct MusicTrackIdentityTests {
    @Test("raw IDs classify into catalog and library domains")
    func rawIDsClassifyIntoCatalogAndLibraryDomains() {
        #expect(MusicTrackIdentity.ids(fromRawID: "i.abc123") == .init(libraryID: "i.abc123"))
        #expect(MusicTrackIdentity.ids(fromRawID: "1440833098") == .init(catalogID: "1440833098"))
        #expect(MusicTrackIdentity.isLibraryID("i.abc123"))
        #expect(!MusicTrackIdentity.isLibraryID("1440833098"))
    }

    @Test("library play parameters provide the catalog ID")
    func libraryPlayParametersProvideTheCatalogID() {
        let json = Data(#"{"id":"i.abc123","kind":"song","isLibrary":true,"catalogId":1440833098}"#.utf8)

        let ids = MusicTrackIdentity.ids(fromRawID: "i.abc123", playParametersData: json)

        #expect(ids == .init(catalogID: "1440833098", libraryID: "i.abc123"))
    }

    @Test("string catalog IDs in play parameters are used")
    func stringCatalogIDsInPlayParametersAreUsed() {
        let json = Data(#"{"id":"i.abc123","kind":"song","isLibrary":true,"catalogId":"1440833098"}"#.utf8)

        let ids = MusicTrackIdentity.ids(fromRawID: "i.abc123", playParametersData: json)

        #expect(ids == .init(catalogID: "1440833098", libraryID: "i.abc123"))
    }

    @Test("catalog play parameters do not invent a library ID")
    func catalogPlayParametersDoNotInventALibraryID() {
        let json = Data(#"{"id":1440833098,"kind":"song"}"#.utf8)

        let ids = MusicTrackIdentity.ids(fromRawID: "1440833098", playParametersData: json)

        #expect(ids == .init(catalogID: "1440833098"))
    }

    @Test("library-shaped play parameters ID is never treated as catalog")
    func libraryShapedPlayParametersIDIsNeverTreatedAsCatalog() {
        let json = Data(#"{"id":"i.xyz","kind":"song"}"#.utf8)

        let ids = MusicTrackIdentity.ids(fromRawID: "1440833098", playParametersData: json)

        #expect(ids == .init(catalogID: "1440833098", libraryID: "i.xyz"))
    }

    @Test("library-shaped catalogId is rejected")
    func libraryShapedCatalogIDIsRejected() {
        let json = Data(#"{"id":"i.abc","kind":"song","isLibrary":true,"catalogId":"i.other"}"#.utf8)

        let ids = MusicTrackIdentity.ids(fromRawID: "i.abc", playParametersData: json)

        #expect(ids == .init(libraryID: "i.abc"))
    }

    @Test("malformed play parameters fall back to raw classification")
    func malformedPlayParametersFallBackToRawClassification() {
        let ids = MusicTrackIdentity.ids(fromRawID: "i.abc", playParametersData: Data("not json".utf8))

        #expect(ids == .init(libraryID: "i.abc"))
    }

    @Test("missing play parameters fall back to raw classification")
    func missingPlayParametersFallBackToRawClassification() {
        let ids = MusicTrackIdentity.ids(fromRawID: "1440833098", playParametersData: nil)

        #expect(ids == .init(catalogID: "1440833098"))
    }

    @Test("snapshot resolved identity prefers captured IDs")
    func snapshotResolvedIdentityPrefersCapturedIDs() {
        let snapshot = TrackSnapshot(
            id: "i.abc123",
            catalogID: "1440833098",
            libraryID: "i.abc123",
            playlistEntryID: nil,
            playlistID: nil,
            title: "Song",
            artistName: "Artist",
            albumTitle: nil,
            artworkURLTemplate: nil,
            durationSeconds: nil
        )

        #expect(snapshot.resolvedIdentity == .init(catalogID: "1440833098", libraryID: "i.abc123"))
    }

    @Test("snapshot resolved identity falls back to classifying the raw ID")
    func snapshotResolvedIdentityFallsBackToClassifyingTheRawID() {
        let librarySnapshot = TrackSnapshot(
            id: "i.abc123",
            catalogID: nil,
            libraryID: nil,
            playlistEntryID: nil,
            playlistID: nil,
            title: "Song",
            artistName: "Artist",
            albumTitle: nil,
            artworkURLTemplate: nil,
            durationSeconds: nil
        )
        let catalogSnapshot = TrackSnapshot(
            id: "1440833098",
            catalogID: nil,
            libraryID: nil,
            playlistEntryID: nil,
            playlistID: nil,
            title: "Song",
            artistName: "Artist",
            albumTitle: nil,
            artworkURLTemplate: nil,
            durationSeconds: nil
        )

        #expect(librarySnapshot.resolvedIdentity == .init(libraryID: "i.abc123"))
        #expect(catalogSnapshot.resolvedIdentity == .init(catalogID: "1440833098"))
    }
}
