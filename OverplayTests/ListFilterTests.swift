import Foundation
import Testing
@testable import Overplay

@Suite("List filter")
struct ListFilterTests {
    private func song(_ title: String, artist: String, album: String?) -> TrackSummaryPresentation {
        TrackSummaryPresentation(id: .init(), title: title, artistName: artist, albumTitle: album, skipCount: 0)
    }

    @Test func matchesAnyFieldIgnoringCaseAndAccents() {
        #expect(ListFilter.matches("", "Anything"))
        #expect(ListFilter.matches("  ", "Anything"))
        #expect(ListFilter.matches("beyonce", "Halo", "Beyoncé"))
        #expect(ListFilter.matches("LAID", "Laid"))
        #expect(!ListFilter.matches("sit", "Laid", nil))
    }

    @Test func eachListMatchesItsOwnFields() {
        let laid = song("Laid", artist: "James", album: "Laid")
        #expect(ListFilter.SongFields.titleOrArtist.matches("james", laid))
        #expect(!ListFilter.SongFields.title.matches("james", laid))
        #expect(ListFilter.SongFields.title.matches("lai", laid))
        let sometimes = song("Sometimes", artist: "James", album: "Laid")
        #expect(ListFilter.SongFields.titleOrAlbum.matches("laid", sometimes))
        #expect(!ListFilter.SongFields.titleOrAlbum.matches("james", sometimes))
    }
}
