import Foundation
import SwiftData

/// Save notifications invalidate inputs, not screens. Ignore known unrelated
/// entities; unknown notification formats conservatively reread presentation.
nonisolated struct LibraryPresentationChange: Sendable {
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
            if let identifiers = value as? [PersistentIdentifier] {
                names.formUnion(identifiers.map(\.entityName))
                hasIdentifiers = true
            } else if let identifiers = value as? Set<PersistentIdentifier> {
                names.formUnion(identifiers.map(\.entityName))
                hasIdentifiers = true
            }
        }
        entityNames = hasIdentifiers ? names : nil
    }

    var affectsLibrary: Bool {
        affectsArtwork || entityNames?.contains("ApplePlayCountRecord") == true
    }

    var affectsArtwork: Bool {
        guard let entityNames else { return true }
        return !entityNames.isDisjoint(with: ["PlaylistRecord", "PlaylistItemRecord", "TrackRecord"])
    }
}
