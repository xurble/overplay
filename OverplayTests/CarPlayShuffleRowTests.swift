import CarPlay
import Testing
import UIKit
@testable import Overplay

@MainActor
@Suite("CarPlay Shuffle and Play row", .serialized)
struct CarPlayShuffleRowTests {
    @Test("the row leads a track list with the shuffle symbol, disabled when there is nothing to play")
    func rowSection() throws {
        let section = CarPlayShuffleRow.section(enabled: true)
        #expect(section.id == "actions")
        #expect(section.header == nil)
        let row = try #require(section.rows.first)
        #expect(section.rows.count == 1)
        #expect(row.id == "shuffle")
        #expect(row.title == "Shuffle and Play")
        #expect(row.artwork == .symbol("shuffle"))
        #expect(row.isEnabled == true)
        #expect(CarPlayShuffleRow.section(enabled: false).rows.first?.isEnabled == false)
    }

    @Test("a tap while the songs load waits for them, then plays once")
    func tapWaitsForSongs() {
        var shuffle = CarPlayShuffleRow()
        shuffle.beginLoading()
        #expect(shuffle.section(hasSongs: false).rows.first?.isEnabled == true)
        let playsAtTap = shuffle.tap()
        #expect(!playsAtTap)
        let playsOnArrival = shuffle.finishLoading(hasSongs: true)
        #expect(playsOnArrival)
        #expect(!shuffle.isLoading)

        // Loaded: the next tap plays at once, and nothing is left waiting.
        let playsLoaded = shuffle.tap()
        #expect(playsLoaded)
        let playsAgain = shuffle.finishLoading(hasSongs: true)
        #expect(!playsAgain)
    }

    @Test("songs arriving without a tap, or a list that turns out empty, play nothing")
    func nothingPlaysUnasked() {
        var shuffle = CarPlayShuffleRow()
        shuffle.beginLoading()
        let playsUntapped = shuffle.finishLoading(hasSongs: true)
        #expect(!playsUntapped)

        shuffle.beginLoading()
        _ = shuffle.tap()
        let playsEmpty = shuffle.finishLoading(hasSongs: false)
        #expect(!playsEmpty)
        // An empty list's row is disabled once loading ends.
        #expect(shuffle.section(hasSongs: false).rows.first?.isEnabled == false)
    }

    @Test("opening another list drops a tap still waiting on the last one")
    func newListDropsWaitingTap() {
        var shuffle = CarPlayShuffleRow()
        shuffle.beginLoading()
        _ = shuffle.tap()
        shuffle.beginLoading()
        let playsOnNewList = shuffle.finishLoading(hasSongs: true)
        #expect(!playsOnNewList)
    }

    @Test("the row runs its action when enabled, and not when disabled")
    func rowTapRunsAction() async throws {
        let renderer = CarPlayListRenderer(loadArtwork: { _ in nil }, record: { _, _ in })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Overplay", sections: [])
        var shuffles = 0
        let actions: [String: @MainActor () async -> Void] = ["shuffle": { shuffles += 1 }]
        let tracks = CarPlayListPresentation.Section(id: "tracks", rows: [.init(id: "one", title: "One")])

        renderer.update(.init(header: .init(title: "Overplay"), sections: [CarPlayShuffleRow.section(enabled: true), tracks]),
                        on: template, actions: actions)
        #expect(template.sections.map { $0.items.count } == [1, 1])
        try await tap(try #require(renderer.items["shuffle"]))
        #expect(shuffles == 1)

        renderer.update(.init(header: .init(title: "Overplay"), sections: [CarPlayShuffleRow.section(enabled: false), tracks]),
                        on: template, actions: actions)
        try await tap(try #require(renderer.items["shuffle"]))
        #expect(shuffles == 1)
    }

    private func tap(_ item: CPListItem) async throws {
        let handler = try #require(item.handler)
        await withCheckedContinuation { continuation in
            handler(item) { continuation.resume() }
        }
    }
}
