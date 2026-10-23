import Testing
@testable import Overplay

@Suite("One True Playlist status")
struct OneTruePlaylistStatusTests {
    @Test("a made playlist shows its name, on any device, even with a request left over")
    func madePlaylist() {
        for canCreate in [true, false] {
            let status = OneTruePlaylistStatus.make(selectedPlaylistID: "p.1", selectedPlaylistName: "Overplay",
                                                    isRequested: true, canCreatePlaylists: canCreate)
            #expect(status.title == "Overplay")
            #expect(status.note.hasPrefix("Overplay made this playlist"))
            #expect(!status.waitsForAnotherDevice)
        }
    }

    @Test("a Mac waits for an iPhone; an iPhone never says it is waiting for itself")
    func requested() {
        let mac = OneTruePlaylistStatus.make(selectedPlaylistID: nil, selectedPlaylistName: nil,
                                             isRequested: true, canCreatePlaylists: false)
        #expect(mac.title == "Waiting for your iPhone")
        #expect(mac.waitsForAnotherDevice)

        let phone = OneTruePlaylistStatus.make(selectedPlaylistID: nil, selectedPlaylistName: nil,
                                               isRequested: true, canCreatePlaylists: true)
        #expect(phone.title == "Not made yet")
        #expect(!phone.waitsForAnotherDevice)
        #expect(!phone.note.contains("Overplay made this playlist"))
    }

    @Test("with nothing made or asked for, the note points to the dashboard")
    func notMade() {
        let status = OneTruePlaylistStatus.make(selectedPlaylistID: nil, selectedPlaylistName: nil,
                                                isRequested: false, canCreatePlaylists: true)
        #expect(status.title == "Not made yet")
        #expect(status.note.contains("dashboard"))
    }
}
