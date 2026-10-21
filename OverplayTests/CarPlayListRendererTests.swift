import CarPlay
import Testing
import UIKit
@testable import Overplay

@MainActor
@Suite("Stable CarPlay lists", .serialized)
struct CarPlayListRendererTests {
    @Test("unchanged refreshes retain rows, sections and artwork without writes")
    func unchangedRefreshesAreSilent() async throws {
        var writes: [MusicKitActivityOperation] = []
        var loads = 0
        let renderer = CarPlayListRenderer(loadArtwork: { _ in
            loads += 1
            return UIImage(systemName: "music.note")
        }, record: { operation, _ in writes.append(operation) })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Library", sections: [])
        let state = CarPlayListPresentation(sections: [.init(id: "root", rows: [
            .init(id: "main", title: "Main", detail: "3 tracks", artwork: .symbol("music.note"))
        ])])
        renderer.update(state, on: template, actions: [:])
        let deadline = ContinuousClock.now + .seconds(2)
        while !writes.contains(.carPlayArtworkUpdate), ContinuousClock.now < deadline { await Task.yield() }
        #expect(loads == 1)
        let row = try #require(renderer.items["main"])
        let section = try #require(template.sections.first)
        #expect(row.image != nil)
        writes.removeAll()
        for _ in 0..<20 { renderer.update(state, on: template, actions: [:]) }
        await Task.yield()
        #expect(writes.isEmpty)
        #expect(loads == 1)
        #expect(renderer.items["main"] === row)
        #expect(template.sections.first === section)
        #expect(row.image != nil)
    }

    @Test("counts and current indicators mutate retained rows; membership changes only replace sections")
    func targetedChanges() throws {
        var details: [String] = []
        let renderer = CarPlayListRenderer(record: { _, detail in details.append(detail) })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Tracks", sections: [])
        var state = CarPlayListPresentation(sections: [.init(id: "tracks", rows: [
            .init(id: "one", title: "One", detail: "0 plays", isPlaying: true),
            .init(id: "two", title: "Two", detail: "0 plays")
        ])])
        renderer.update(state, on: template, actions: [:])
        let first = try #require(renderer.items["one"])
        let second = try #require(renderer.items["two"])
        let section = try #require(template.sections.first)
        details.removeAll()
        state.sections[0].rows[0].detail = "1 play"
        state.sections[0].rows[0].isPlaying = false
        state.sections[0].rows[1].isPlaying = true
        renderer.update(state, on: template, actions: [:])
        #expect(template.sections.first === section)
        #expect(renderer.items["one"] === first)
        #expect(renderer.items["two"] === second)
        #expect(first.detailText == "1 play")
        #expect(!first.isPlaying && second.isPlaying)
        #expect(details.count == 2)
        #expect(!details.contains { $0.hasPrefix("sections") })
        state.sections[0].rows.removeFirst()
        renderer.update(state, on: template, actions: [:])
        #expect(renderer.items["one"] == nil)
        #expect(renderer.items["two"] === second)
        #expect(details.last == "sections rows=1")
    }

    @Test("stale artwork completion cannot overwrite a newer row request")
    func staleArtworkIsIgnored() async throws {
        var continuation: CheckedContinuation<UIImage?, Never>?
        var artworkWrites = 0
        let renderer = CarPlayListRenderer(loadArtwork: { artwork in
            if artwork == .symbol("old") {
                return await withCheckedContinuation { continuation = $0 }
            }
            return UIImage(systemName: "star")
        }, record: { operation, _ in if operation == .carPlayArtworkUpdate { artworkWrites += 1 } })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Library", sections: [])
        var state = CarPlayListPresentation(sections: [.init(id: "root", rows: [
            .init(id: "main", title: "Main", artwork: .symbol("old"))
        ])])
        renderer.update(state, on: template, actions: [:])
        let deadline = ContinuousClock.now + .seconds(2)
        while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        let pending = try #require(continuation)
        state.sections[0].rows[0].artwork = .symbol("new")
        renderer.update(state, on: template, actions: [:])
        pending.resume(returning: UIImage(systemName: "music.note"))
        while artworkWrites == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(artworkWrites == 1)
        #expect(renderer.items["main"]?.image != nil)
    }

    @Test("a track list's header carries the list's art, title, count and an icon-only shuffle button")
    func headerIsApplied() async throws {
        var details: [String] = []
        var loaded: [CarPlayListPresentation.Row.Artwork] = []
        let renderer = CarPlayListRenderer(loadArtwork: { artwork in
            loaded.append(artwork)
            return UIImage(systemName: "star")
        }, record: { _, detail in details.append(detail) })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Overplay", sections: [])
        let art = CarPlayListPresentation.Row.Artwork.track(url: "https://example.com/{w}x{h}.jpg", playlistID: "p", size: 512)
        var state = CarPlayListPresentation(
            header: .init(title: "Overplay", subtitle: "2 tracks", artwork: art, shuffleActionID: "shuffle", canShuffle: true),
            sections: [.init(id: "tracks", rows: [
                .init(id: "one", title: "One", artwork: .symbol("music.note")),
                .init(id: "two", title: "Two")
            ])]
        )
        renderer.update(state, on: template, actions: ["shuffle": {}])

        let header = try #require(template.listHeader as? CPListTemplateDetailsHeader)
        #expect(header.title == "Overplay")
        #expect(header.subtitle == "2 tracks")
        #expect(header.wantsAdaptiveBackgroundStyle)
        let button = try #require(header.actionButtons.first)
        #expect(header.actionButtons.count == 1)
        #expect(button.title == nil)
        #expect(button.isEnabled)
        #expect(template.sections.map { $0.items.count } == [2])

        // The header's art loads first, then is applied to a new header.
        let deadline = ContinuousClock.now + .seconds(2)
        while loaded.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(loaded.first == art)
        #expect(template.listHeader !== header)

        // An unchanged refresh leaves the header alone; an empty list disables Shuffle.
        details.removeAll()
        renderer.update(state, on: template, actions: ["shuffle": {}])
        #expect(!details.contains("header"))
        state.header?.canShuffle = false
        renderer.update(state, on: template, actions: ["shuffle": {}])
        #expect(details.contains("header"))
        let disabled = try #require((template.listHeader as? CPListTemplateDetailsHeader)?.actionButtons.first)
        #expect(!disabled.isEnabled)

        state.header = nil
        renderer.update(state, on: template, actions: [:])
        #expect(template.listHeader == nil)
        #expect(details.last == "header cleared")
    }

    @Test("a list waits for its header art before a push, and a header arriving mid-push waits for the push to end")
    func headerIsNotReplacedDuringAPush() async throws {
        var details: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let renderer = CarPlayListRenderer(loadArtwork: { _ in
            await withCheckedContinuation { release = $0 }
            return UIImage(systemName: "star")
        }, record: { _, detail in details.append(detail) })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Overplay", sections: [])
        let art = CarPlayListPresentation.Row.Artwork.track(url: "https://example.com/{w}x{h}.jpg", playlistID: "p", size: 512)
        renderer.update(CarPlayListPresentation(
            header: .init(title: "Overplay", subtitle: "2 tracks", artwork: art, shuffleActionID: "shuffle", canShuffle: true),
            sections: [.init(id: "tracks", rows: [.init(id: "one", title: "One")])]
        ), on: template, actions: [:])
        let placeholder = try #require(template.listHeader)

        // The art never arrives in time: the wait ends at its limit.
        let started = ContinuousClock.now
        await renderer.headerArtwork(within: .milliseconds(100))
        #expect(ContinuousClock.now - started >= .milliseconds(100))

        // The push starts; the art lands mid-push and is held until it ends.
        renderer.holdHeaderChanges()
        details.removeAll()
        try #require(release).resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(template.listHeader === placeholder)
        renderer.releaseHeaderChanges()
        #expect(template.listHeader !== placeholder)
        #expect(details == ["header"])

        // Settled art ends the wait at once.
        let again = ContinuousClock.now
        await renderer.headerArtwork(within: .seconds(2))
        #expect(ContinuousClock.now - again < .milliseconds(500))
    }

    @Test("the playing indicator sits over the row art, as in Music")
    func playingIndicatorIsLeading() throws {
        let renderer = CarPlayListRenderer(record: { _, _ in })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Tracks", sections: [])
        renderer.update(CarPlayListPresentation(sections: [.init(id: "tracks", rows: [
            .init(id: "one", title: "One", isPlaying: true)
        ])]), on: template, actions: [:])
        let item = try #require(renderer.items["one"])
        #expect(item.isPlaying)
        #expect(item.playingIndicatorLocation == .leading)
    }
}
