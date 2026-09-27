import Foundation
import Synchronization
@preconcurrency import MusicKit

/// Rebuildable process-local material, shared across ModelContexts. It is never
/// part of SwiftData/CloudKit identity and disappears on restart/account refresh.
nonisolated final class DevicePlaybackCache: Sendable {
    static let shared = DevicePlaybackCache()
    private let resources = Mutex<[UUID: Data]>([:])

    func data(for id: UUID) -> Data? { resources.withLock { $0[id] } }
    func set(_ data: Data?, for id: UUID) { resources.withLock { $0[id] = data } }
    func removeAll() { resources.withLock { $0.removeAll() } }

    /// Resolve the complete requested queue before replacing playback. A cache
    /// miss cannot silently shorten the queue or drop the selected song.
    @MainActor static func prepare(
        _ tracks: [TrackRecord],
        load: (MusicResourceReference) async throws -> Data = loadResource
    ) async throws {
        var prepared: [(UUID, Data)] = []
        for track in tracks {
            if let cached = shared.data(for: track.id),
               (try? JSONDecoder().decode(Track.self, from: cached)) != nil { continue }
            try Task.checkCancellation()
            let reference: MusicResourceReference
            if let id = track.libraryID { reference = .library(id, scope: track.libraryScope) }
            else if let id = track.catalogID { reference = .catalog(id) }
            else { throw MusicLibrarySongResolver.ResolutionError.unresolved(track.title) }
            prepared.append((track.id, try await load(reference)))
        }
        try Task.checkCancellation()
        for (id, data) in prepared { shared.set(data, for: id) }
    }

    @MainActor private static func loadResource(_ reference: MusicResourceReference) async throws -> Data {
        let id = reference.value
        let song: Song
        switch reference.domain {
        case .librarySong:
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(id))
            request.limit = 2
            let items = try await request.response().items
            guard items.count == 1, !items.hasNextBatch, let resolved = items.first,
                  resolved.id.rawValue == id else {
                throw MusicLibrarySongResolver.ResolutionError.unresolved(id)
            }
            song = resolved
        case .catalogSong:
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
            let items = try await request.response().items
            guard items.count == 1, let resolved = items.first, resolved.id.rawValue == id else {
                throw MusicLibrarySongResolver.ResolutionError.unresolved(id)
            }
            song = resolved
        }
        return try JSONEncoder().encode(Track.song(song))
    }
}
