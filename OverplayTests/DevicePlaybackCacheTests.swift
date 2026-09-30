import Foundation
import MusicKit
import Testing
@testable import Overplay

@MainActor
struct DevicePlaybackCacheTests {
    @Test func coldQueueUsesBoundedBatchesAndReusesPreparedData() async throws {
        let tracks = (0..<205).map { TrackRecord(libraryID: "i.batch-\($0)", title: "Song \($0)", artistName: "Artist") }
        defer { for track in tracks { track.musicKitPlaybackData = nil } }
        var nativeBatches: [[String]] = []
        var webBatches: [[String]] = []
        let lookup: ([String]) async throws -> [String: Song] = { ids in
            try await DevicePlaybackCache.loadLibrarySongs(ids, nativeLookup: { batch in
                nativeBatches.append(batch)
                return []
            }, request: { url in
                let ids = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value).components(separatedBy: ",")
                webBatches.append(ids)
                let resources = try ids.reversed().flatMap { id -> [[String: Any]] in
                    let envelope = try #require(JSONSerialization.jsonObject(with: Self.libraryResponse(id: id)) as? [String: Any])
                    return try #require(envelope["data"] as? [[String: Any]])
                }
                return try JSONSerialization.data(withJSONObject: ["data": resources])
            })
        }
        try await DevicePlaybackCache.prepare(tracks, libraryLookup: lookup)
        #expect(nativeBatches.map(\.count) == [100, 100, 5])
        #expect(webBatches == nativeBatches)
        for track in tracks {
            let cached = try JSONDecoder().decode(Track.self, from: #require(track.musicKitPlaybackData))
            #expect(cached.id.rawValue == track.libraryID)
        }
        try await DevicePlaybackCache.prepare(tracks, libraryLookup: lookup)
        #expect(webBatches.count == 3)
    }

    @Test func incompleteBatchDoesNotPublishAnyPreparedTracks() async throws {
        let tracks = ["i.first", "i.second"].map { TrackRecord(libraryID: $0, title: $0, artistName: "Artist") }
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare(tracks, libraryLookup: { ids in
                try await DevicePlaybackCache.loadLibrarySongs(ids, nativeLookup: { _ in [] }, request: { _ in
                    try Self.libraryResponse(id: "i.first")
                })
            })
        }
        #expect(tracks.allSatisfy { $0.musicKitPlaybackData == nil })
    }

    static func libraryResponse(id: String, type: String = "library-songs", playable: Bool = true, more: Bool = false) throws -> Data {
        var attributes: [String: Any] = ["name": "Upload", "artistName": "Artist", "albumName": "Album", "genreNames": []]
        if playable { attributes["playParams"] = ["id": id, "kind": "song", "isLibrary": true] }
        var envelope: [String: Any] = ["data": [["id": id, "type": type, "attributes": attributes]]]
        if more { envelope["next"] = "/v1/me/library/songs?offset=1" }
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    @Test func nativeMissResolvesLibraryOnlySongThroughWebEndpoint() async throws {
        let track = TrackRecord(libraryID: "i.upload", title: "Upload", artistName: "Artist")
        defer { track.musicKitPlaybackData = nil }
        try await DevicePlaybackCache.prepare([track]) { reference in
            let song = try await DevicePlaybackCache.loadLibrarySong(reference.value, nativeLookup: { _ in nil }, request: { url in
                #expect(url.path == "/v1/me/library/songs")
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "ids", value: "i.upload")])
                return try Self.libraryResponse(id: "i.upload")
            })
            return try JSONEncoder().encode(Track.song(song))
        }
        let cached = try JSONDecoder().decode(Track.self, from: #require(track.musicKitPlaybackData))
        #expect(cached.id.rawValue == "i.upload")
        #expect(cached.playParameters != nil)
        #expect(track.catalogID == nil)
        #expect(track.libraryID == "i.upload")
    }

    @Test func nativeMatchAvoidsWebRequest() async throws {
        let data = try Self.libraryResponse(id: "i.native")
        let song = try await DevicePlaybackCache.loadLibrarySong("i.native", nativeLookup: { _ in nil }, request: { _ in data })
        let result = try await DevicePlaybackCache.loadLibrarySong("i.native", nativeLookup: { _ in song }, request: { _ in
            Issue.record("An exact native result must not need network access")
            return Data()
        })
        #expect(result.id == song.id)
    }

    @Test func differentNativeIDRequiresWebProof() async throws {
        let native = try await DevicePlaybackCache.loadLibrarySong("device-id", nativeLookup: { _ in nil }, request: { _ in try Self.libraryResponse(id: "device-id") })
        let result = try await DevicePlaybackCache.loadLibrarySong("i.web", nativeLookup: { _ in native }, request: { _ in try Self.libraryResponse(id: "i.web") })
        #expect(result.id.rawValue == "i.web")
    }

    @Test(arguments: ["empty", "wrongID", "wrongType", "unplayable", "more", "duplicate"])
    func invalidWebResponseCannotPopulateCache(kind: String) async throws {
        let track = TrackRecord(libraryID: "i.requested", title: "Upload", artistName: "Artist")
        let data: Data
        switch kind {
        case "empty": data = Data(#"{"data":[]}"#.utf8)
        case "wrongID": data = try Self.libraryResponse(id: "i.other")
        case "wrongType": data = try Self.libraryResponse(id: "i.requested", type: "songs")
        case "unplayable": data = try Self.libraryResponse(id: "i.requested", playable: false)
        case "more": data = try Self.libraryResponse(id: "i.requested", more: true)
        default:
            let envelope = try #require(JSONSerialization.jsonObject(with: Self.libraryResponse(id: "i.requested")) as? [String: Any])
            let resources = try #require(envelope["data"] as? [[String: Any]])
            data = try JSONSerialization.data(withJSONObject: ["data": resources + resources])
        }
        await #expect(throws: DevicePlaybackCache.PreparationError.self) {
            try await DevicePlaybackCache.prepare([track]) { reference in
                let song = try await DevicePlaybackCache.loadLibrarySong(reference.value, nativeLookup: { _ in nil }, request: { _ in data })
                return try JSONEncoder().encode(Track.song(song))
            }
        }
        #expect(track.musicKitPlaybackData == nil)
    }

    @Test(arguments: [
        ([String](), false, "returned no songs"),
        (["i.first", "i.second"], false, "returned multiple songs (2)"),
        (["i.requested"], true, "more pages available"),
        (["native-device-id"], false, "different song identifier")
    ])
    func lookupFailureIncludesTrackAndResponse(ids: [String], more: Bool, reason: String) async throws {
        let track = TrackRecord(libraryID: "i.requested", title: "Example Song", artistName: "Example Artist")
        do {
            try await DevicePlaybackCache.prepare([track]) { reference in
                try DevicePlaybackCache.validateLookup(reference, returnedIDs: ids, hasNextBatch: more)
                Issue.record("Expected lookup rejection")
                return Data()
            }
            Issue.record("Expected playback preparation failure")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Playback preparation failed"))
            #expect(message.contains("Example Song"))
            #expect(message.contains("Example Artist"))
            #expect(message.contains("Library song lookup for i.requested"))
            #expect(message.contains(reason))
            #expect(message.contains("Returned IDs: [\(ids.joined(separator: ", "))]"))
            #expect(message.contains("More pages: \(more)"))
            #expect(!message.contains("playlist was not imported"))
        }
        #expect(track.musicKitPlaybackData == nil)
    }

    @Test func exactLookupStillSucceeds() throws {
        try DevicePlaybackCache.validateLookup(.library("i.exact"), returnedIDs: ["i.exact"], hasNextBatch: false)
        try DevicePlaybackCache.validateLookup(.catalog("123"), returnedIDs: ["123"], hasNextBatch: false)
    }

    @Test func underlyingRequestErrorRetainsDomainAndCode() async {
        let track = TrackRecord(catalogID: "123", title: "Example", artistName: "Artist")
        do {
            try await DevicePlaybackCache.prepare([track], load: { _ in
                throw NSError(domain: "MusicTestError", code: 42, userInfo: [NSLocalizedDescriptionKey: "Request denied"])
            })
            Issue.record("Expected request failure")
        } catch {
            #expect(error.localizedDescription.contains("Catalog song lookup for 123"))
            #expect(error.localizedDescription.contains("Request denied [MusicTestError, code 42]"))
        }
    }

    @Test func missingIdentityIsDistinctFromLookupFailure() async {
        let track = TrackRecord(title: "Unidentified", artistName: "Artist")
        do {
            try await DevicePlaybackCache.prepare([track]) { _ in
                Issue.record("Must not request a song without an ID")
                return Data()
            }
            Issue.record("Expected missing identity failure")
        } catch {
            #expect(error.localizedDescription.contains("no saved library or catalog song ID"))
            #expect(error.localizedDescription.contains(track.id.uuidString))
        }
    }

    @Test func cancellationRemainsCancellation() async {
        let track = TrackRecord(libraryID: "i.cancelled", title: "Example", artistName: "Artist")
        await #expect(throws: CancellationError.self) {
            try await DevicePlaybackCache.prepare([track], load: { _ in throw CancellationError() })
        }
    }
}
