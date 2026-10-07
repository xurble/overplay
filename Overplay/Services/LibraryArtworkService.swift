import Foundation
import MusicKit
import SwiftData

/// Missing artwork is metadata work, not a playlist change. Refresh it even
/// when Apple reports unchanged playlist contents; never rebuild memberships.
@MainActor
enum LibraryArtworkService {
    static func refreshMissingArtwork(in context: ModelContext, playbackController: PlaybackController? = nil) async {
        guard MusicAuthorization.currentStatus == .authorized else { return }
        await discardUnreachableArtwork(in: context)
        do {
            let changed = try await repair(in: context) {
                try await MusicIdentityResolver.shared.enrich($0, includeCandidates: false)
            }
            if changed > 0 { playbackController?.refreshPlayCountMetadata(context: context) }
        } catch {
            StartupProfiler.mark("Artwork metadata refresh failed: \(error.localizedDescription)")
        }
    }

    /// Artwork for uploaded library tracks is served through a pre-signed URL
    /// that expires after a day. Once one has failed unrecoverably the stored
    /// template is worthless, so drop it and let `repair` ask for a current
    /// one rather than re-requesting a dead credential forever.
    @discardableResult
    static func discardUnreachableArtwork(
        in context: ModelContext,
        cache: ArtworkCacheService = .shared
    ) async -> Int {
        let unreachable = await cache.permanentlyFailedSourceURLs()
        guard !unreachable.isEmpty else { return 0 }
        let tracks = ((try? TrackRecordRepository.allTracks(in: context)) ?? []).filter {
            $0.artworkURLTemplate.map(unreachable.contains) == true
        }
        guard !tracks.isEmpty else {
            await cache.clearPermanentFailures(unreachable)
            return 0
        }
        let previous = tracks.map { ($0, $0.artworkURLTemplate, $0.updatedAt) }
        for track in tracks {
            track.artworkURLTemplate = nil
            track.updatedAt = .now
        }
        do { try context.save() } catch {
            for (track, artwork, date) in previous { track.artworkURLTemplate = artwork; track.updatedAt = date }
            return 0
        }
        await cache.clearPermanentFailures(unreachable)
        return tracks.count
    }

    @discardableResult
    static func repair(in context: ModelContext,
                       absences: ArtworkAbsenceStore = ArtworkAbsenceStore(),
                       now: Date = .now,
                       fetch: ([TrackSnapshot]) async throws -> [TrackSnapshot]) async throws -> Int {
        var known = absences.entries().filter { !$0.value.isExpired(at: now) }
        let targets = try TrackRecordRepository.allTracks(in: context).filter {
            PortableArtworkReference.validated($0.artworkURLTemplate) == nil
                && ($0.libraryID != nil || $0.catalogID != nil)
                && known[$0.id]?.matches($0) != true
        }
        guard !targets.isEmpty else { return 0 }
        let inputs = targets.map { track in
            TrackSnapshot(id: track.id.uuidString, catalogID: track.catalogID, libraryID: track.libraryID,
                playlistEntryID: nil, playlistID: nil, title: track.title, artistName: track.artistName,
                albumTitle: track.albumTitle, artworkURLTemplate: nil, durationSeconds: track.durationSeconds)
        }
        let results = try await fetch(inputs)
        try Task.checkCancellation()
        let byID = results.firstValueDictionary(keyedBy: \.id)
        // `fetch` throws on any failed lookup, so a returned result without
        // usable artwork is a confirmed absence, not a transient failure.
        for input in inputs {
            guard let id = UUID(uuidString: input.id), let result = byID[input.id] else { continue }
            known[id] = PortableArtworkReference.validated(result.artworkURLTemplate) == nil
                ? ArtworkAbsenceStore.Entry(checkedAt: now, libraryID: input.libraryID, catalogID: input.catalogID)
                : nil
        }
        absences.save(known)
        var previous: [(TrackRecord, String?, Date)] = []
        for input in inputs {
            guard let id = UUID(uuidString: input.id), let result = byID[input.id],
                  let url = PortableArtworkReference.validated(result.artworkURLTemplate),
                  let track = try TrackRecordRepository.track(id: id, in: context),
                  track.libraryID == input.libraryID, track.catalogID == input.catalogID,
                  PortableArtworkReference.validated(track.artworkURLTemplate) == nil else { continue }
            previous.append((track, track.artworkURLTemplate, track.updatedAt))
            track.artworkURLTemplate = url
            track.updatedAt = .now
        }
        guard !previous.isEmpty else { return 0 }
        do { try context.save() }
        catch {
            for (track, artwork, date) in previous { track.artworkURLTemplate = artwork; track.updatedAt = date }
            throw error
        }
        return previous.count
    }
}

/// Tracks whose artwork lookup succeeded but returned none, such as an
/// upload never given artwork (#60), so the repair stops asking each cycle.
/// Kept on this device only. An entry lapses after `recheckInterval`, which
/// is how artwork added later is found, or as soon as the track's library or
/// catalog ID changes.
@MainActor
struct ArtworkAbsenceStore {
    struct Entry: Codable, Equatable {
        var checkedAt: Date
        var libraryID: String?
        var catalogID: String?

        func isExpired(at date: Date) -> Bool {
            date.timeIntervalSince(checkedAt) >= ArtworkAbsenceStore.recheckInterval
        }

        func matches(_ track: TrackRecord) -> Bool {
            libraryID == track.libraryID && catalogID == track.catalogID
        }
    }

    nonisolated static let recheckInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let key = "LibraryArtworkService.confirmedAbsences"
    var defaults: UserDefaults = .standard

    func entries() -> [UUID: Entry] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([UUID: Entry].self, from: data)) ?? [:]
    }

    func save(_ entries: [UUID: Entry]) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }
}
