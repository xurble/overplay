import Foundation
import Testing
@testable import Overplay

@Suite("Playlist library ID resolver")
struct PlaylistLibraryIDResolverTests {
    @Test("returns stored ID when it exists in the library")
    func returnsStoredIDWhenItExistsInLibrary() {
        let resolved = PlaylistLibraryIDResolver.resolvedMusicPlaylistID(
            storedID: "p.stored",
            name: "Overplay",
            libraryPlaylists: [
                .init(id: "p.stored", name: "Overplay"),
                .init(id: "p.other", name: "Other")
            ]
        )

        #expect(resolved == "p.stored")
    }

    @Test("heals to unique library playlist with the same name")
    func healsToUniqueLibraryPlaylistWithSameName() {
        let resolved = PlaylistLibraryIDResolver.resolvedMusicPlaylistID(
            storedID: "p.stale",
            name: "Overplay",
            libraryPlaylists: [
                .init(id: "p.canonical", name: "Overplay")
            ]
        )

        #expect(resolved == "p.canonical")
    }

    @Test("returns nil when stored ID is missing and name is unknown")
    func returnsNilWhenStoredIDIsMissingAndNameIsUnknown() {
        let resolved = PlaylistLibraryIDResolver.resolvedMusicPlaylistID(
            storedID: "p.stale",
            name: nil,
            libraryPlaylists: [
                .init(id: "p.canonical", name: "Overplay")
            ]
        )

        #expect(resolved == nil)
    }

    @Test("returns nil when multiple library playlists share the same name")
    func returnsNilWhenMultipleLibraryPlaylistsShareSameName() {
        let resolved = PlaylistLibraryIDResolver.resolvedMusicPlaylistID(
            storedID: "p.stale",
            name: "Inbox",
            libraryPlaylists: [
                .init(id: "p.one", name: "Inbox"),
                .init(id: "p.two", name: "Inbox")
            ]
        )

        #expect(resolved == nil)
    }
}
