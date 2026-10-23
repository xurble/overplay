import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("One True Playlist prompt")
struct OneTruePlaylistPromptControllerTests {
    private final class Recorder {
        var rebuilds = 0
        var fulfils = 0
        var messages: [String] = []
        var isFulfilling = false
        var exists: Bool? = false
        /// Runs while the presence lookup is in flight.
        var duringLookup: () -> Void = {}
    }

    private func library() throws -> ModelContainer {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        context.insert(OverplaySettings(selectedPlaylistID: "p.overplay", selectedPlaylistName: "Overplay"))
        context.insert(PlaylistRecord(musicPlaylistID: "p.overplay", name: "Overplay", role: .oneTruePlaylist, writePolicy: .managed))
        try context.save()
        return container
    }

    private func controller(_ recorder: Recorder) -> OneTruePlaylistPromptController {
        var presence = OneTruePlaylistPresenceService()
        presence.canCreatePlaylists = { true }
        presence.playlistExists = { _ in
            recorder.duringLookup()
            return recorder.exists
        }
        return OneTruePlaylistPromptController(dependencies: .init(
            presence: presence,
            isFulfilling: { recorder.isFulfilling },
            fulfilPending: { _ in recorder.fulfils += 1 },
            rebuild: { _ in
                recorder.rebuilds += 1
                return .init(name: "Overplay", addedCount: 3, skippedCount: 0)
            },
            show: { recorder.messages.append($0) }
        ))
    }

    private let missing = OneTruePlaylistPrompt.missing(name: "Overplay", playlistID: "p.overplay")

    @Test("Make It Again rebuilds only when the playlist is still missing")
    func makeItAgainChecksFirst() async throws {
        let container = try library()
        let recorder = Recorder()
        let controller = controller(recorder)

        recorder.exists = true
        await controller.make(missing, in: container.mainContext)
        #expect(recorder.rebuilds == 0)
        #expect(recorder.messages.last == "Your Overplay playlist is in Apple Music, so nothing was made.")

        recorder.exists = nil
        await controller.make(missing, in: container.mainContext)
        #expect(recorder.rebuilds == 0)
        #expect(recorder.messages.last?.hasPrefix("Overplay couldn’t check Apple Music") == true)

        // Another device made it again: the prompt's ID is stale.
        recorder.exists = false
        await controller.make(.missing(name: "Overplay", playlistID: "p.old"), in: container.mainContext)
        #expect(recorder.rebuilds == 0)

        await controller.make(missing, in: container.mainContext)
        #expect(recorder.rebuilds == 1)
        #expect(recorder.messages.last == "Made “Overplay” again in Apple Music with 3 songs.")
    }

    @Test("no prompt while the requested playlist is being made")
    func noPromptWhileFulfilling() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let settings = OverplaySettings()
        settings.pendingOneTruePlaylistRequestedAt = .now
        container.mainContext.insert(settings)
        try container.mainContext.save()
        let recorder = Recorder()
        let controller = controller(recorder)

        recorder.isFulfilling = true
        await controller.check(in: container.mainContext)
        #expect(controller.prompt == nil)

        recorder.isFulfilling = false
        await controller.check(in: container.mainContext)
        #expect(controller.prompt == .requestedByMac(sourceName: nil))
    }

    @Test("Not Now during a lookup holds: the finished lookup asks nothing")
    func declineDuringLookupHolds() async throws {
        let container = try library()
        let recorder = Recorder()
        let controller = controller(recorder)
        recorder.duringLookup = { controller.decline() }

        await controller.check(in: container.mainContext, checksPresence: true)
        #expect(controller.prompt == nil)

        recorder.duringLookup = {}
        await controller.check(in: container.mainContext, checksPresence: true)
        #expect(controller.prompt == nil)
    }
}
