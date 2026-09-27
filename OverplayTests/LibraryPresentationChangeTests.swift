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
        let counters = LibraryPresentationChange(entityNames: ["ApplePlayCountRecord"])
        #expect(counters.affectsLibrary)
        #expect(!counters.affectsArtwork)
        #expect(LibraryPresentationChange(entityNames: ["PlaylistItemRecord"]).affectsLibrary)
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
