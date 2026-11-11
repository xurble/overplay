import Foundation
import SwiftData

enum SettingsRepository {
    struct Convergence {
        let keeper: OverplaySettings
        let removedIDs: Set<UUID>
    }

    /// The stored row, or unsaved defaults when this store has none, as a
    /// device can mid-import. A read never creates a row: a new one syncs, and
    /// restoration needs exactly one. Unsaved defaults keep playback and every
    /// other caller working; writing to them changes nothing.
    static func settings(in context: ModelContext) throws -> OverplaySettings {
        try storedRows(in: context).first ?? OverplaySettings()
    }

    /// Duplicates converge as Inbox buckets do: every device keeps the same
    /// row, the oldest and then the lowest UUID, and it takes what only the
    /// others knew, so no configuration is lost. Nil when there is nothing to
    /// converge.
    @discardableResult
    static func convergeDuplicates(in context: ModelContext) throws -> Convergence? {
        let rows = try storedRows(in: context)
        guard let keeper = rows.first, rows.count > 1 else { return nil }
        let oneTruePlaylistIDs = Set(try context.fetch(FetchDescriptor<PlaylistRecord>())
            .filter { $0.role == .oneTruePlaylist }.map(\.musicPlaylistID))
        // Restoration waits for the selected playlist, so a selection left
        // over from a deleted playlist must not win over one that is here.
        let selection = rows.first { $0.selectedPlaylistID.map(oneTruePlaylistIDs.contains) == true }
            ?? rows.first { $0.selectedPlaylistID != nil }
        if let selection {
            keeper.selectedPlaylistID = selection.selectedPlaylistID
            keeper.selectedPlaylistName = selection.selectedPlaylistName
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
        try context.fetch(FetchDescriptor<OverplaySettings>()).sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
    }

    /// A deliberate write, so unlike a read it makes the row if there is none:
    /// the selection would otherwise be lost, and convergence settles a clash.
    static func selectPlaylist(
        _ playlist: AppleMusicPlaylist,
        writePolicy: PlaylistWritePolicy = .managed,
        in context: ModelContext
    ) throws {
        let settings: OverplaySettings
        if let stored = try storedRows(in: context).first {
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
