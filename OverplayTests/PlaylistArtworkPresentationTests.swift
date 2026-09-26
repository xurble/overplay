import Testing
@testable import Overplay

@MainActor
struct PlaylistArtworkPresentationTests {
    @Test func dismissWithoutSavingAndReopenWithDifferentSettings() {
        let presentation = PlaylistArtworkPresentation()
        var saved: [(PlaylistCollageLayout, PlaylistCollageStroke)] = []
        presentation.request = .init(layout: .pile, stroke: .none) { saved.append(($0, $1)) }
        // Cancel and swipe dismissal clear the sheet binding without saving.
        presentation.request = nil
        #expect(saved.isEmpty)
        presentation.request = .init(layout: .grid3, stroke: .black) { saved.append(($0, $1)) }
        presentation.apply(layout: .grid8, stroke: .white)
        #expect(presentation.request == nil)
        #expect(saved.count == 1)
        #expect(saved.first?.0 == .grid8)
        #expect(saved.first?.1 == .white)
        presentation.apply(layout: .pile, stroke: .none)
        #expect(saved.count == 1)
    }
}
