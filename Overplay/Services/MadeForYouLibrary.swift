import Foundation
@preconcurrency import MusicKit
import Observation
import SwiftData

/// Apple Music's Made For You playlists (`MFY-001`): the personal mixes and
/// Replay that Apple makes for this account. Listed on the dashboard and
/// played like a deep dive, never added to Recent Deep Dives; offered as
/// Inbox sources, linked by catalog ID and read live at each sync. A library
/// copy would stop updating.
@MainActor
@Observable
final class MadeForYouLibrary {
    static let shared = MadeForYouLibrary()

    /// A Made For You playlist, kept on this device between launches so the
    /// row shows at once.
    struct Item: Codable, Identifiable, Hashable, Sendable {
        /// The catalog playlist ID.
        var id: String
        var name: String
        var artworkURL: String?
        var subtitle: String?

        var collection: PlaybackCollection {
            PlaybackCollection(kind: .madeForYou, catalogID: id, title: name)
        }

        /// The mix as an Inbox source.
        var sourcePlaylist: AppleMusicPlaylist {
            AppleMusicPlaylist(id: id, name: name, trackCount: nil)
        }
    }

    private static let defaultsKey = "overplay.madeForYou.items"
    /// Apple refreshes the mixes weekly; reading them once an hour is plenty.
    private static let refreshInterval: TimeInterval = 3600

    private(set) var items: [Item]
    private(set) var isRefreshing = false
    private var refreshedAt: Date?

    private init() {
        items = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    /// Reads the mixes from Apple Music's personal recommendations, at most
    /// once an hour. Normally not before the launch quiet period ends
    /// (`LOAD-001`); setup, where nothing plays, starts at once.
    func refresh(force: Bool = false, waitsForLaunchQuiet: Bool = true) async {
        guard !isRefreshing, MusicAuthorization.currentStatus == .authorized else { return }
        if !force, let refreshedAt, Date.now.timeIntervalSince(refreshedAt) < Self.refreshInterval { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if waitsForLaunchQuiet { try? await Task.sleep(until: BackgroundMusicKitWorkPolicy.launchQuietEnds) }
        do {
            let recommendations = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: "made for you") {
                try await MusicPersonalRecommendationsRequest().response().recommendations
            }
            let found = Self.items(from: recommendations.flatMap { Array($0.playlists) })
            refreshedAt = .now
            guard !found.isEmpty, found != items else { return }
            items = found
            UserDefaults.standard.set(try? JSONEncoder().encode(found), forKey: Self.defaultsKey)
        } catch {
            TrackMetadataDiagnostics.log("made for you refresh failed: \(error.localizedDescription)")
        }
    }

    /// Personal mixes and Replay, once each, in Apple's order.
    nonisolated static func items(from playlists: [Playlist]) -> [Item] {
        var seen = Set<String>()
        return playlists.compactMap { playlist in
            guard playlist.kind == .personalMix || playlist.kind == .replay,
                  seen.insert(playlist.id.rawValue).inserted else { return nil }
            return Item(
                id: playlist.id.rawValue,
                name: playlist.name,
                artworkURL: playlist.artwork?.url(width: 512, height: 512)?.absoluteString,
                subtitle: playlist.shortDescription ?? playlist.curatorName
            )
        }
    }

    /// The mix's songs from the catalog, bounded as a deep dive's are.
    static func songs(in item: Item) async throws -> [LibraryBrowser.Entry] {
        let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(item.id))
        guard let playlist = try await MusicKitActivityLog.shared.measure(.catalogResourceFetch, detail: "made for you playlist", {
            try await request.response().items.first
        }) else { return [] }
        let detailed = try await MusicKitActivityLog.shared.measure(.playlistTrackFetch, detail: "made for you tracks") {
            try await playlist.with([.tracks])
        }
        var tracks = Array(detailed.tracks ?? [])
        var batch = detailed.tracks
        while tracks.count < 200, batch?.hasNextBatch == true {
            batch = try await MusicKitActivityLog.shared.measure(.playlistTrackFetch, detail: "made for you tracks page") {
                try await batch?.nextBatch()
            }
            tracks += Array(batch ?? [])
        }
        return LibraryBrowser.unique(tracks.compactMap(LibraryBrowser.entry))
    }

    /// The shared play action for a mix, from every surface: its songs as a
    /// deep dive never added to Recent Deep Dives. No song shuffles.
    @discardableResult
    static func play(
        _ item: Item, entries: [LibraryBrowser.Entry], startingAt catalogSongID: String?,
        controller: PlaybackController, context: ModelContext
    ) async -> Bool {
        let tracks = Dictionary(entries.map { ($0.song.catalogID, $0.track) }, uniquingKeysWith: { first, _ in first })
        return await controller.playCollection(item.collection, songs: entries.map(\.song), startingAt: catalogSongID,
                                               recordsRecent: false, tracks: tracks, context: context)
    }

    /// The mixes to offer as Inbox sources. Each is linked by its catalog ID
    /// and read live at every sync (`MFY-001`).
    func sourceCandidates(excludingIDs linkedIDs: Set<String> = []) -> [Item] {
        items.filter { !linkedIDs.contains($0.id) }
    }
}
