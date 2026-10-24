import Foundation
import Observation
import SwiftData

/// A device must observe a restored configuration before any surface may
/// maintain, reconcile or sync the library. Absence is never a reset request.
@MainActor
@Observable
final class LibraryRestorationService {
    enum RestorationError: LocalizedError, Equatable {
        case waitingForCloud, incompleteLibrary, cloud(String), existingLibrary
        /// Nothing to restore: the store is empty and may start a new library.
        case setupNeeded
        /// iCloud holds a library that has not arrived yet: keep waiting.
        case restoringFromCloud
        var errorDescription: String? {
            switch self {
            case .restoringFromCloud:
                "Your library is on its way from iCloud."
            case .setupNeeded:
                "Overplay has no library yet."
            case .waitingForCloud:
                "Your library has not arrived from iCloud yet. Check iCloud access and keep Overplay open on the device with your library, then retry."
            case .incompleteLibrary:
                "Your library is still arriving from iCloud. Overplay will wait before changing it."
            case .cloud(let message):
                "iCloud could not restore your library: \(message)"
            case .existingLibrary:
                "Existing library data was found. It has been left unchanged."
            }
        }
    }

    private(set) var isReady = false
    private(set) var hasImported = false
    private(set) var cloudError: String?
    private(set) var importRevision = 0
    private(set) var canCreateLibrary = false
    /// What iCloud said about this account's library, asked once the store
    /// is found empty.
    private(set) var cloudLibrary = CloudLibraryState.unknown
    @ObservationIgnored private let defaults: UserDefaults
    private static let receiptKey = "overplay.v2.restoredSettingsID"

    init(defaults: UserDefaults = AppPersistence.libraryDefaults) { self.defaults = defaults }

    func cloudImportFinished(error: String?) {
        cloudError = error
        if error == nil { hasImported = true; importRevision += 1 }
    }

    /// Read-only, including on an empty store or during a partial CloudKit batch.
    static func restoredSettings(in context: ModelContext) throws -> OverplaySettings? {
        let settings = try context.fetch(FetchDescriptor<OverplaySettings>())
        guard settings.count == 1, let settings = settings.first else { return nil }
        let playlists = try context.fetch(FetchDescriptor<PlaylistRecord>())
        guard playlists.contains(where: { $0.isTriageBucket }) else { return nil }
        if let selected = settings.selectedPlaylistID {
            guard playlists.contains(where: { $0.musicPlaylistID == selected && $0.role == .oneTruePlaylist }) else { return nil }
        } else if settings.completedRebuildID != nil {
            return nil
        }
        let tracks = Set(try context.fetch(FetchDescriptor<TrackRecord>()).map(\.id))
        let playlistIDs = Set(playlists.map(\.id))
        let sourceIDs = Set(playlists.map(\.musicPlaylistID))
        var items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        // A membership whose track a merge absorbed is left over, not still
        // arriving: waiting for that track would wait forever.
        if items.contains(where: { !tracks.contains($0.trackID) }) {
            let mergedAway = try PlaylistItemRepository.mergedAwayTrackIDs(in: context)
            items.removeAll { !tracks.contains($0.trackID) && mergedAway.contains($0.trackID) }
        }
        guard items.allSatisfy({
            tracks.contains($0.trackID) && playlistIDs.contains($0.playlistID)
                && Set($0.sourceMusicPlaylistIDs).isSubset(of: sourceIDs)
        }) else { return nil }
        return settings
    }

    static func isEmpty(in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<OverplaySettings>()) == 0
            && context.fetchCount(FetchDescriptor<PlaylistRecord>()) == 0
            && context.fetchCount(FetchDescriptor<TrackRecord>()) == 0
            && context.fetchCount(FetchDescriptor<PlaylistItemRecord>()) == 0
            && context.fetchCount(FetchDescriptor<HistoryEvent>()) == 0
            && context.fetchCount(FetchDescriptor<ApplePlayCountRecord>()) == 0
            && context.fetchCount(FetchDescriptor<ListenEvent>()) == 0
            && context.fetchCount(FetchDescriptor<RecentCollectionRecord>()) == 0
    }

    func prepare(
        in context: ModelContext,
        cloudEnabled: Bool = true,
        hasLegacyStore: Bool = LibraryRestorationService.hasLegacyStore,
        locallyRebuiltID: UUID? = LibraryRestorationService.locallyRebuiltID,
        attempts: Int = 60,
        wait: () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) },
        checkCloudLibrary: () async -> CloudLibraryState = { .unknown }
    ) async throws {
        if isReady { return }
        // An empty store on a mirrored device: ask iCloud whether a library
        // exists, rather than inferring a first run from what has arrived.
        if cloudEnabled, cloudLibrary == .unknown, !hasLegacyStore, cloudError == nil {
            let read = ModelContext(context.container)
            read.autosaveEnabled = false
            if try Self.isEmpty(in: read) {
                cloudLibrary = await checkCloudLibrary()
            }
        }
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            // A fresh context sees later cloud deliveries without retaining an
            // earlier partial settings object across suspension points.
            let read = ModelContext(context.container)
            read.autosaveEnabled = false
            if let settings = try Self.restoredSettings(in: read) {
                let acceptedLocally = defaults.string(forKey: Self.receiptKey) == settings.id.uuidString
                let builtLocally = locallyRebuiltID != nil && settings.completedRebuildID == locallyRebuiltID
                if acceptedLocally || builtLocally || (hasImported && cloudError == nil && (settings.selectedPlaylistID != nil || settings.pendingOneTruePlaylistRequestedAt != nil)) || !cloudEnabled {
                    accept(settings)
                    return
                }
            }
            // iCloud said it has nothing, or (unanswered) an import finished
            // and delivered nothing. A library iCloud holds is never replaced.
            let mayStart = !cloudEnabled || cloudLibrary == .empty || (cloudLibrary == .unknown && hasImported)
            canCreateLibrary = try !hasLegacyStore && mayStart
                && cloudError == nil && (try Self.isEmpty(in: read))
            if let cloudError { throw RestorationError.cloud(cloudError) }
            // Nothing will arrive to wait for: go straight to setup.
            if canCreateLibrary { throw RestorationError.setupNeeded }
            // A library is coming: imports retry, however long it takes.
            if cloudLibrary == .exists && !hasImported { throw RestorationError.restoringFromCloud }
            if attempt + 1 < attempts { try await wait() }
        }
        if cloudLibrary == .exists { throw RestorationError.restoringFromCloud }
        throw hasImported ? RestorationError.incompleteLibrary : RestorationError.waitingForCloud
    }

    /// Explicit first-time setup only; never called by bootstrap or by a timeout.
    func createLibrary(in context: ModelContext, hasLegacyStore: Bool = LibraryRestorationService.hasLegacyStore) throws {
        guard canCreateLibrary, !hasLegacyStore, cloudError == nil,
              try Self.isEmpty(in: context) else { throw RestorationError.existingLibrary }
        let settings = OverplaySettings()
        context.insert(settings)
        context.insert(PlaylistRecord(musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
                                      name: PlaylistRecord.triageBucketName, role: .triageBucket,
                                      writePolicy: .incomingOnly))
        do { try context.save() } catch { context.rollback(); throw error }
        accept(settings)
    }

    static func recordLocalConfiguration(_ settings: OverplaySettings, defaults: UserDefaults = AppPersistence.libraryDefaults) {
        defaults.set(settings.id.uuidString, forKey: receiptKey)
    }

    private func accept(_ settings: OverplaySettings) {
        Self.recordLocalConfiguration(settings, defaults: defaults)
        canCreateLibrary = false
        isReady = true
    }

    /// A first-run build's own store is never the legacy library's successor.
    static var hasLegacyStore: Bool {
        !AppPersistence.isFirstRunBuild && FileManager.default.fileExists(atPath: URL.applicationSupportDirectory.appendingPathComponent("default.store").path)
    }

    /// Only the device which performed the explicit cutover has this file.
    /// A cloud receipt alone cannot prove that this device restored its graph.
    static var locallyRebuiltID: UUID? {
        // The first-run build's empty store is never the rebuilt library.
        guard !AppPersistence.isFirstRunBuild else { return nil }
        let urls = [LibraryRebuildService.configurationURL,
                    URL.documentsDirectory.appendingPathComponent("overplay-library-rebuild-v2.completed.json")]
        return urls.lazy.compactMap { url -> UUID? in
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(LibraryRebuildConfiguration.self, from: data),
                  (try? config.validate()) != nil else { return nil }
            return config.rebuildID
        }.first
    }
}
