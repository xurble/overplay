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
                       fetch: ([TrackSnapshot]) async throws -> [TrackSnapshot]) async throws -> Int {
        let targets = try TrackRecordRepository.allTracks(in: context).filter {
            PortableArtworkReference.validated($0.artworkURLTemplate) == nil
                && ($0.libraryID != nil || $0.catalogID != nil)
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
