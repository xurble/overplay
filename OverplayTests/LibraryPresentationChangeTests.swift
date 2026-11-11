import Foundation
import SwiftData
import Testing
@testable import Overplay

struct LibraryPresentationChangeTests {
    @Test func unrelatedSavesDoNotInvalidateLibraryOrArtwork() {
        for entities: Set<String> in [[], ["HistoryEvent"], ["OverplaySettings"]] {
            let change = LibraryPresentationChange(entityNames: entities)
            #expect(!change.affectsLibrary)
            #expect(!change.affectsArtwork)
        }
        let membership = Schema.entityName(for: PlaylistItemRecord.self)
        #expect(LibraryPresentationChange(entityNames: [membership]).affectsLibrary)
        let recents = LibraryPresentationChange(entityNames: [Schema.entityName(for: RecentCollectionRecord.self)])
        #expect(recents.affectsLibrary)
        #expect(!recents.affectsArtwork)
        #expect(LibraryPresentationChange(entityNames: nil).affectsLibrary)
    }

    @Test func notificationIdentifiersSelectRelevantEntities() throws {
        let id = try PersistentIdentifier.identifier(for: "test", entityName: "HistoryEvent", primaryKey: "1")
        let save = Notification(name: ModelContext.didSave, userInfo: [
            ModelContext.NotificationKey.updatedIdentifiers.rawValue: [id]
        ])
        #expect(!LibraryPresentationChange(notification: save).affectsLibrary)
        #expect(LibraryPresentationChange(notification: Notification(name: ModelContext.didSave)).affectsLibrary)
    }
}

/// Real saves through a real container, because the names and keys a save
/// reports are SwiftData's, not ours.
@MainActor
@Suite("LibraryPresentationChange real saves")
struct LibraryPresentationChangeRealSaveTests {
    private final class SaveLog: @unchecked Sendable {
        var notifications: [Notification] = []
    }

    private struct Library {
        let container: ModelContainer
        let settings = OverplaySettings()
        let playlist = PlaylistRecord(musicPlaylistID: "playlist", name: "Main", role: .oneTruePlaylist)
        let track = TrackRecord(title: "Song", artistName: "Artist")
        let item: PlaylistItemRecord
        var context: ModelContext { container.mainContext }

        init() throws {
            container = try OverplayTestSupport.makeModelContainer()
            item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
            context.insert(settings)
            context.insert(playlist)
            context.insert(track)
            context.insert(item)
            try context.save()
        }
    }

    /// The one change a save reported. The notification arrives during `save`.
    private func change(in context: ModelContext, after edit: () throws -> Void) throws -> LibraryPresentationChange {
        let log = SaveLog()
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) {
            log.notifications.append($0)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try edit()
        try context.save()
        #expect(log.notifications.count == 1)
        return try #require(log.notifications.first.map(LibraryPresentationChange.init(notification:)))
    }

    @Test func insertingLibraryRowsAffectsLibraryAndArtwork() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        for insert: (ModelContext) -> Void in [
            { $0.insert(PlaylistRecord(musicPlaylistID: "new", name: "New")) },
            { $0.insert(TrackRecord(title: "New", artistName: "Artist")) },
            { $0.insert(PlaylistItemRecord(playlistID: UUID(), trackID: UUID())) },
        ] {
            let saved = try change(in: context) { insert(context) }
            #expect(saved.affectsArtwork)
            #expect(saved.affectsLibrary)
        }
    }

    @Test func removingAMembershipAffectsLibraryAndArtwork() throws {
        let library = try Library()
        let saved = try change(in: library.context) { library.context.delete(library.item) }
        #expect(saved.affectsArtwork)
        #expect(saved.affectsLibrary)
    }

    @Test func updatingAPlaylistOrTrackAffectsLibraryAndArtwork() throws {
        let library = try Library()
        var saved = try change(in: library.context) { library.playlist.name = "Renamed" }
        #expect(saved.affectsArtwork)
        saved = try change(in: library.context) { library.track.artworkURLTemplate = "https://example.com/{w}x{h}.jpg" }
        #expect(saved.affectsArtwork)
        #expect(saved.affectsLibrary)
    }

    /// Recents already refreshed CarPlay before; it must carry on doing so,
    /// and never rebuild collages.
    @Test func recentsAffectLibraryButNotArtwork() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let saved = try change(in: context) {
            context.insert(RecentCollectionRecord(
                collection: PlaybackCollection(kind: .album, catalogID: "1", title: "Album"),
                songs: [], artworkURLTemplate: nil, playedAt: .now
            ))
        }
        #expect(saved.affectsLibrary)
        #expect(!saved.affectsArtwork)
    }

    /// The expensive path (review finding PF-3): a counted play writes a
    /// membership update and ledger rows, and must trigger neither consumer.
    @Test func aCountedPlayTriggersNeitherConsumer() throws {
        let library = try Library()
        let session = TrackPlaySession(
            trackID: "track", sessionStartDate: .now, lastObservedPlaybackTime: 95,
            durationSeconds: 100, hasEvaluated: false
        )
        let saved = try change(in: library.context) {
            EvictionEngine.evaluateSkip(
                item: library.item, playlist: library.playlist, session: session,
                transitionWasNaturalCompletion: true, settings: library.settings, context: library.context
            )
        }
        #expect(library.item.playthroughCount == 1)
        #expect(!saved.affectsLibrary)
        #expect(!saved.affectsArtwork)
    }

    /// Maintenance saves the playlist it renders, which now matches the
    /// filter, so a pass with nothing new to do must not save again.
    @Test func collageMaintenanceConvergesWithoutSaving() throws {
        for artwork in [nil, "https://example.com/{w}x{h}.jpg"] {
            let library = try Library()
            library.track.artworkURLTemplate = artwork
            try library.context.save()
            try PlaylistCollageService.prepareSnapshots(in: library.context)

            let log = SaveLog()
            let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: library.context, queue: nil) {
                log.notifications.append($0)
            }
            defer { NotificationCenter.default.removeObserver(token) }
            try PlaylistCollageService.prepareSnapshots(in: library.context)
            #expect(log.notifications.isEmpty)
        }
    }

    @Test func anApplePlayCountRowTriggersNeitherConsumer() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let saved = try change(in: context) {
            context.insert(ApplePlayCountRecord(itemID: UUID(), mergedItemID: UUID(), deviceID: "device"))
        }
        #expect(!saved.affectsLibrary)
        #expect(!saved.affectsArtwork)
    }
}
