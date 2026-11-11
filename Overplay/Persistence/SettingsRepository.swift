import Foundation
import SwiftData

enum SettingsRepository {
    struct Convergence {
        let keeper: OverplaySettings
        let removedIDs: Set<UUID>
    }

    /// The stored row, or unsaved defaults when this store has none, as a
    /// device can mid-import. A read never creates a row: a new one syncs, and
    /// a second row has to be converged. Unsaved defaults keep playback and
    /// every other caller working; writing to them changes nothing.
    static func settings(in context: ModelContext) throws -> OverplaySettings {
        try storedSettings(in: context) ?? OverplaySettings()
    }

    /// The row every device reads while duplicates exist, or nil when the
    /// store has none. Every settings read goes through `keeper(of:)`, so a
    /// duplicate that arrives mid-session changes nothing a surface reads.
    static func storedSettings(in context: ModelContext) throws -> OverplaySettings? {
        keeper(of: try context.fetch(FetchDescriptor<OverplaySettings>()))
    }

    /// The oldest row, then the lowest UUID, as for Inbox buckets: every
    /// device picks the same one.
    static func keeper(of rows: [OverplaySettings]) -> OverplaySettings? {
        ordered(rows).first
    }

    /// Duplicates converge on `keeper(of:)`, which takes what only the
    /// others knew, so no configuration is lost. Destructive: it deletes the
    /// other rows and demotes any other One True Playlist. Only
    /// `LibraryRestorationService.convergeSettingsAfterImport` calls it, once
    /// the library has settled. Nil when there is nothing to converge.
    @discardableResult
    static func convergeDuplicates(in context: ModelContext) throws -> Convergence? {
        let rows = try storedRows(in: context)
        guard let keeper = rows.first, rows.count > 1 else { return nil }
        let oneTruePlaylistIDs = Set(try context.fetch(FetchDescriptor<PlaylistRecord>())
            .filter { $0.role == .oneTruePlaylist }.map(\.musicPlaylistID))
        // A selection left over from a deleted playlist must not win over
        // one that is here.
        let selection = rows.first { $0.selectedPlaylistID.map(oneTruePlaylistIDs.contains) == true }
            ?? rows.first { $0.selectedPlaylistID != nil }
        if let selection {
            keeper.selectedPlaylistID = selection.selectedPlaylistID
            keeper.selectedPlaylistName = selection.selectedPlaylistName
        }
        // Two devices that set up at once each made a One True Playlist. The
        // one not kept goes into the Inbox, as when the user switches, so
        // each song stays in exactly one of the One True Playlist, the Inbox
        // or Retired.
        if let selected = keeper.selectedPlaylistID, oneTruePlaylistIDs.contains(selected) {
            try PlaylistRepository.demoteOneTruePlaylists(except: selected, in: context)
        }
        let others = rows.dropFirst()
        keeper.completedRebuildID = keeper.completedRebuildID ?? others.lazy.compactMap(\.completedRebuildID).first
        if keeper.pendingOneTruePlaylistRequestedAt == nil,
           let request = others.first(where: { $0.pendingOneTruePlaylistRequestedAt != nil }) {
            keeper.pendingOneTruePlaylistRequestedAt = request.pendingOneTruePlaylistRequestedAt
            keeper.pendingOneTruePlaylistSourceID = request.pendingOneTruePlaylistSourceID
            keeper.pendingOneTruePlaylistSourceName = request.pendingOneTruePlaylistSourceName
        }
        keeper.updatedAt = .now
        let removedIDs = Set(others.map(\.id))
        others.forEach(context.delete)
        try context.save()
        return Convergence(keeper: keeper, removedIDs: removedIDs)
    }

    /// Sorted here for the UUID tie-break: independently created rows can
    /// carry equal dates through CloudKit.
    private static func storedRows(in context: ModelContext) throws -> [OverplaySettings] {
        ordered(try context.fetch(FetchDescriptor<OverplaySettings>()))
    }

    private static func ordered(_ rows: [OverplaySettings]) -> [OverplaySettings] {
        rows.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// A deliberate write, so unlike a read it makes the row if there is none:
    /// the selection would otherwise be lost, and convergence settles a clash.
    static func selectPlaylist(
        _ playlist: AppleMusicPlaylist,
        writePolicy: PlaylistWritePolicy = .managed,
        in context: ModelContext
    ) throws {
        let settings: OverplaySettings
        if let stored = try storedSettings(in: context) {
            settings = stored
        } else {
            settings = OverplaySettings()
            context.insert(settings)
        }
        try PlaylistRepository.setOneTruePlaylist(playlist, writePolicy: writePolicy, in: context)
        settings.selectedPlaylistID = playlist.id
        settings.selectedPlaylistName = playlist.name
        settings.updatedAt = .now
        try context.save()
    }

    static func save(_ settings: OverplaySettings, in context: ModelContext) throws {
        settings.skipThresholdPercentage = min(max(settings.skipThresholdPercentage, 1), 99)
        settings.minimumSkipListeningSeconds = max(settings.minimumSkipListeningSeconds, 0)
        settings.playthroughThresholdPercentage = min(max(settings.playthroughThresholdPercentage, 1), 100)
        settings.updatedAt = .now
        try context.save()
    }
}
