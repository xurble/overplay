import CarPlay
import Testing
@testable import Overplay

@MainActor
@Suite("CarPlay playlist sections")
struct CarPlayPlaylistSectionFactoryTests {
    @Test("Shuffle and Play precedes the unchanged track rows", arguments: [PlaylistPlaybackScope.active, .retired])
    func shuffleComesFirst(scope: PlaylistPlaybackScope) throws {
        let tracks = [CPListItem(text: "First", detailText: nil), CPListItem(text: "Second", detailText: nil)]
        let sections = CarPlayPlaylistSectionFactory.sections(trackItems: tracks, scope: scope) { _ in }
        #expect(sections.count == 2)
        let action = try #require(sections[0].items.first as? CPListItem)
        #expect(action.text == "Shuffle and Play")
        #expect(action.image != nil)
        #expect(action.isEnabled)
        #expect(sections[1].items.count == 2)
        #expect(sections[1].items[0] as? CPListItem === tracks[0])
        #expect(sections[1].items[1] as? CPListItem === tracks[1])
    }

    @Test("the action forwards the displayed scope and completes after playback", arguments: [PlaylistPlaybackScope.active, .retired])
    func actionUsesDisplayedScope(scope: PlaylistPlaybackScope) async throws {
        var receivedScopes: [PlaylistPlaybackScope] = []
        let sections = CarPlayPlaylistSectionFactory.sections(
            trackItems: [CPListItem(text: "Track", detailText: nil)], scope: scope
        ) { receivedScope in
            await Task.yield()
            receivedScopes.append(receivedScope)
        }
        let action = try #require(sections[0].items.first as? CPListItem)
        let handler = try #require(action.handler)
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                handler(action) { continuation.resume() }
            }
        }
        #expect(action.isEnabled)
        #expect(receivedScopes == [scope, scope])
    }

    @Test("empty playlists retain a disabled action and cannot start playback")
    func emptyListDisablesShuffle() async throws {
        var didPlay = false
        let sections = CarPlayPlaylistSectionFactory.sections(trackItems: [], scope: .retired) { _ in
            didPlay = true
        }
        let action = try #require(sections[0].items.first as? CPListItem)
        let empty = try #require(sections[1].items.first as? CPListItem)
        #expect(!action.isEnabled)
        #expect(empty.text == "No playable tracks")
        #expect(!empty.isEnabled)
        let handler = try #require(action.handler)
        await withCheckedContinuation { continuation in
            handler(action) { continuation.resume() }
        }
        #expect(!didPlay)
    }
}
