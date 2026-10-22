import CloudKit
import Foundation

/// Whether this iCloud account already holds an Overplay library, asked of
/// CloudKit directly, so a new device restores instead of offering setup.
enum CloudLibraryState: Equatable {
    /// Unknown: no answer yet, iCloud unavailable, or the request failed.
    case unknown
    /// Nothing in iCloud: a genuine first run.
    case empty
    /// Records exist: a library to restore, however long it takes to arrive.
    case exists
}

@MainActor
enum CloudLibraryProbe {
    /// The zone SwiftData's CloudKit mirroring keeps every record in. It can
    /// exist with no records (each device's mirroring creates it on launch),
    /// so records are asked for, not the zone.
    static let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: CKCurrentUserDefaultName)

    /// One record, no fields: enough to tell an empty zone from a library.
    /// Deleted records are not reported without a change token.
    static func check(containerIdentifier: String) async -> CloudLibraryState {
        let container = CKContainer(identifier: containerIdentifier)
        do {
            guard try await container.accountStatus() == .available else { return .unknown }
            let changes = try await container.privateCloudDatabase.recordZoneChanges(
                inZoneWith: zoneID, since: nil, desiredKeys: [], resultsLimit: 1
            )
            let state: CloudLibraryState = changes.modificationResultsByID.isEmpty && !changes.moreComing ? .empty : .exists
            StartupProfiler.mark("iCloud library check: \(state)")
            return state
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            StartupProfiler.mark("iCloud library check: no zone")
            return .empty
        } catch {
            StartupProfiler.mark("iCloud library check failed: \(error.localizedDescription)")
            return .unknown
        }
    }

    /// The container this build is entitled to, mirrored or not: lets the
    /// first-run build ask about the real library without opening it.
    static var entitledContainerIdentifier: String? {
        (Bundle.main.object(forInfoDictionaryKey: "OverplayCloudKitContainerIdentifier") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The live check for the app's store, or unknown when it is not mirrored.
    static func checkAppStore() async -> CloudLibraryState {
        guard AppPersistence.cloudEnabled, let identifier = AppRuntime.shared.cloudKitContainerIdentifier else { return .unknown }
        return await check(containerIdentifier: identifier)
    }
}
