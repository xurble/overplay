import Foundation
import SwiftData

/// Append-only CloudKit evidence. A device inserts its own record instead of
/// updating a shared field. No uniqueness constraint or custom CloudKit merge
/// policy is needed: duplicate delivery is harmless to the state join.
@Model
final class ApplePlayCountRecord {
    #Index<ApplePlayCountRecord>([\.itemID])

    var id: UUID = UUID()
    var itemID: UUID = UUID()
    var deviceID: String = ""
    var stateData: Data = Data()
    var hasState: Bool = false
    var lineageIDs: [UUID] = []
    var resetAt: Date = Date.distantPast
    var resetID: String = ""
    var creditedCount: Int = 0

    init(itemID: UUID, state: ApplePlayCountState, deviceID: String) {
        self.itemID = itemID
        self.deviceID = deviceID
        stateData = (try? JSONEncoder().encode(state)) ?? Data()
        hasState = true
        lineageIDs = state.lineageIDs
        resetAt = state.resetAt
        resetID = state.resetID
        creditedCount = state.count
    }

    init(itemID: UUID, mergedItemID: UUID, deviceID: String) {
        self.itemID = itemID
        self.deviceID = deviceID
        lineageIDs = [mergedItemID]
    }

    var state: ApplePlayCountState? { try? JSONDecoder().decode(ApplePlayCountState.self, from: stateData) }
}
