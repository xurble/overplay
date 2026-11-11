import Foundation
import SwiftData

/// Save notifications invalidate inputs, not screens. Ignore known unrelated
/// entities; unknown notification formats conservatively reread presentation.
///
/// Names come from the schema: the `...Record` names are typealiases, and a
/// save reports the stored model's name.
nonisolated struct LibraryPresentationChange: Sendable {
    private static let playlistEntity = Schema.entityName(for: PlaylistRecord.self)
    private static let membershipEntity = Schema.entityName(for: PlaylistItemRecord.self)
    private static let trackEntity = Schema.entityName(for: TrackRecord.self)
    private static let recentEntity = Schema.entityName(for: RecentCollectionRecord.self)

    /// What changed. An update to a membership row is left out: every counted
    /// play or skip makes one, and collage maintenance and CarPlay's list
    /// rebuild are too expensive to run per count. Counts reach the surfaces
    /// through `PlaybackController` instead, and `LibraryAppleCountV2` is
    /// ignored for the same reason.
    var entityNames: Set<String>?

    init(entityNames: Set<String>?) { self.entityNames = entityNames }

    init(notification: Notification) {
        guard let info = notification.userInfo,
              info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] as? Bool != true else {
            entityNames = nil
            return
        }
        var names = Set<String>()
        var hasIdentifiers = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            let value = info[key.rawValue] ?? info[key]
            let identifiers = (value as? [PersistentIdentifier]) ?? (value as? Set<PersistentIdentifier>).map(Array.init)
            guard let identifiers else { continue }
            hasIdentifiers = true
            names.formUnion(identifiers.map(\.entityName).filter {
                key != .updatedIdentifiers || $0 != Self.membershipEntity
            })
        }
        entityNames = hasIdentifiers ? names : nil
    }

    var affectsLibrary: Bool {
        affectsArtwork || entityNames?.contains(Self.recentEntity) == true
    }

    var affectsArtwork: Bool {
        guard let entityNames else { return true }
        return !entityNames.isDisjoint(with: [Self.playlistEntity, Self.membershipEntity, Self.trackEntity])
    }
}
