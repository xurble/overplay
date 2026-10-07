import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct LibraryArtworkServiceTests {
    @Test func repairsMetadataWithoutChangingIdentityMembershipOrCounts() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let track = TrackRecord(libraryID: "i.upload", title: "The Hand", artistName: "Artist")
        context.insert(track)
        let item = PlaylistItemRecord(playlistID: UUID(), trackID: track.id, skipCount: 7)
        context.insert(item)
        try context.save()
        let count = try await LibraryArtworkService.repair(in: context) { snapshots in
            var result = snapshots
            result[0].artworkURLTemplate = "https://example.com/art/{w}x{h}.jpg"
            result[0].catalogID = "a-new-match-must-not-change-identity"
            return result
        }
        #expect(count == 1)
        #expect(track.catalogID == nil)
        #expect(track.libraryID == "i.upload")
        #expect(item.skipCount == 7)
        #expect(try context.fetchCount(FetchDescriptor<PlaylistItemRecord>()) == 1)
        #expect(track.artworkURLTemplate == "https://example.com/art/{w}x{h}.jpg")
        #expect(try await LibraryArtworkService.repair(in: context) { _ in
            Issue.record("Already populated artwork must not be fetched again")
            return []
        } == 0)
    }

    @Test func failureDoesNotEraseArtOrPartiallyWriteMetadata() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let track = TrackRecord(libraryID: "i.upload", title: "Song", artistName: "Artist")
        container.mainContext.insert(track)
        try container.mainContext.save()
        await #expect(throws: URLError.self) {
            try await LibraryArtworkService.repair(in: container.mainContext) { _ in
                throw URLError(.notConnectedToInternet)
            }
        }
        #expect(track.artworkURLTemplate == nil)
        #expect(!container.mainContext.hasChanges)
    }

    // MARK: - Confirmed absence (#60)

    private func absenceStore() -> (ArtworkAbsenceStore, () -> Void) {
        let suite = "LibraryArtworkServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ArtworkAbsenceStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func noArtwork(_ snapshots: [TrackSnapshot]) -> [TrackSnapshot] { snapshots }

    @Test func aConfirmedAbsenceIsNotAskedAgainAcrossCyclesOrRestart() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let upload = TrackRecord(libraryID: "i.upload", title: "Bigger Boys And Stolen Sweethearts", artistName: "Arctic Monkeys")
        context.insert(upload)
        let item = PlaylistItemRecord(playlistID: UUID(), trackID: upload.id, skipCount: 3)
        context.insert(item)
        try context.save()
        let (store, cleanUp) = absenceStore(); defer { cleanUp() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        var asked: [[String?]] = []
        #expect(try await LibraryArtworkService.repair(in: context, absences: store, now: start) {
            asked.append($0.map(\.libraryID)); return noArtwork($0)
        } == 0)
        #expect(asked == [["i.upload"]])

        // A later cycle, and a fresh store reading the same defaults after relaunch.
        let relaunched = ArtworkAbsenceStore(defaults: store.defaults)
        for absences in [store, relaunched] {
            #expect(try await LibraryArtworkService.repair(in: context, absences: absences, now: start.addingTimeInterval(86_400)) { _ in
                Issue.record("A confirmed absence must not be fetched again"); return []
            } == 0)
        }
        #expect(upload.artworkURLTemplate == nil && upload.libraryID == "i.upload")
        #expect(item.skipCount == 3)
    }

    @Test func aFailedLookupIsNotRecordedAsAbsence() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        context.insert(TrackRecord(libraryID: "i.upload", title: "Song", artistName: "Artist"))
        try context.save()
        let (store, cleanUp) = absenceStore(); defer { cleanUp() }

        await #expect(throws: URLError.self) {
            try await LibraryArtworkService.repair(in: context, absences: store) { _ in throw URLError(.timedOut) }
        }
        #expect(store.entries().isEmpty)
        var asked = 0
        _ = try await LibraryArtworkService.repair(in: context, absences: store) { asked += 1; return noArtwork($0) }
        #expect(asked == 1)
    }

    @Test func artworkAddedLaterIsFoundAfterTheRecheckIntervalOrAnIdentityChange() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let aged = TrackRecord(libraryID: "i.aged", title: "Aged", artistName: "Artist")
        let rematched = TrackRecord(libraryID: "i.old", title: "Rematched", artistName: "Artist")
        context.insert(aged)
        context.insert(rematched)
        try context.save()
        let (store, cleanUp) = absenceStore(); defer { cleanUp() }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await LibraryArtworkService.repair(in: context, absences: store, now: start) { noArtwork($0) }

        rematched.libraryID = "i.new"
        try context.save()
        let art = "https://example.com/art/{w}x{h}.jpg"
        var asked: [String?] = []
        let withArt: ([TrackSnapshot]) -> [TrackSnapshot] = { snapshots in
            asked += snapshots.map(\.libraryID)
            return snapshots.map { var copy = $0; copy.artworkURLTemplate = art; return copy }
        }
        #expect(try await LibraryArtworkService.repair(in: context, absences: store, now: start.addingTimeInterval(60), fetch: withArt) == 1)
        #expect(asked == ["i.new"])
        #expect(rematched.artworkURLTemplate == art && aged.artworkURLTemplate == nil)

        let later = start.addingTimeInterval(ArtworkAbsenceStore.recheckInterval)
        #expect(try await LibraryArtworkService.repair(in: context, absences: store, now: later, fetch: withArt) == 1)
        #expect(aged.artworkURLTemplate == art)
        #expect(store.entries().isEmpty)
    }

    @Test func anExpiredArtworkCredentialIsDroppedSoItCanBeResolvedAgain() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let expired = "https://store-035.blobstore.apple.com/sq/82/96/ff/image?X-Amz-Signature=aaaa"
        let dead = TrackRecord(libraryID: "i.upload", title: "Uploaded", artistName: "Artist",
                               artworkURLTemplate: expired)
        let alive = TrackRecord(libraryID: "i.other", title: "Catalog", artistName: "Artist",
                                artworkURLTemplate: "https://example.com/art/{w}x{h}.jpg")
        context.insert(dead)
        context.insert(alive)
        try context.save()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverplayArtworkRepairTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkCacheService(rootDirectory: directory, downloader: { _ in
            throw NSError(domain: ArtworkCacheService.httpErrorDomain, code: 406)
        })
        #expect(await cache.artworkFileURL(for: expired, pixelSize: 512) == nil)

        #expect(await LibraryArtworkService.discardUnreachableArtwork(in: context, cache: cache) == 1)
        #expect(dead.artworkURLTemplate == nil)
        #expect(alive.artworkURLTemplate == "https://example.com/art/{w}x{h}.jpg")
        #expect(await cache.permanentlyFailedSourceURLs().isEmpty)
        // Now eligible for the repair pass that asks MusicKit for a fresh URL.
        #expect(try await LibraryArtworkService.repair(in: context) { snapshots in
            var result = snapshots
            result[0].artworkURLTemplate = "https://example.com/fresh/{w}x{h}.jpg"
            return result
        } == 1)
        #expect(dead.artworkURLTemplate == "https://example.com/fresh/{w}x{h}.jpg")
    }
}
