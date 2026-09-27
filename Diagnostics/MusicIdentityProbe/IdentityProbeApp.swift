import Foundation
import MusicKit
import SwiftUI

/// Standalone diagnostic app. Intentionally has no dependency on Overplay,
/// SwiftData, CloudKit, MusicLibrary.shared, or a music player.
@main
struct IdentityProbeApp: App {
    var body: some Scene {
        WindowGroup { IdentityProbeView() }
    }
}

private struct IdentityProbeView: View {
    @State private var probe = IdentityProbe()

    var body: some View {
        ScrollView {
            Text(probe.output)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .task { await probe.run() }
    }
}

#Preview { IdentityProbeView() }

@MainActor @Observable
private final class IdentityProbe {
    var output = "Read-only MusicKit identity probe\n"
    private var started = false
    private let cases: [(title: String, library: String, numeric: String, catalog: String?)] = [
        ("Archie, Marry Me", "i.O1RQbZGuVYYl7v", "-3140821922437280474", "878984806"),
        ("All Nighter", "i.1YBNxGGsqAAPdr", "-2540034726386153049", nil),
        ("California Stars", "i.1YBNkWOHqAAPdr", "7155078121927443764", "925214201")
    ]

    private func record(_ label: String, _ value: String) {
        output += "\n[\(label)]\n\(value)\n"
        print("IDENTITY_PROBE [\(label)] \(value)")
        // Only a diagnostic report is written. No application store is opened.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? output.write(to: documents.appendingPathComponent("music-identity-probe.txt"), atomically: true, encoding: .utf8)
        }
    }

    private func describe(_ song: Song) -> String {
        "id=\(song.id.rawValue) title=\(song.title) artist=\(song.artistName) album=\(song.albumTitle ?? "nil") duration=\(song.duration.map(String.init(describing:)) ?? "nil") isrc=\(song.isrc ?? "nil") artworkScheme=\(song.artwork?.url(width: 128, height: 128)?.scheme ?? "nil")"
    }

    func run() async {
        guard !started else { return }
        started = true
        let authorization = await MusicAuthorization.request()
        record("authorization", String(describing: authorization))
        guard authorization == .authorized else { return }
        record("environment", "\(ProcessInfo.processInfo.operatingSystemVersionString); Designed for iPad; \(Date())")

        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 100
            let playlists = try await request.response()
            record("library playlists", "count=\(playlists.items.count)")
            for playlist in playlists.items where playlist.name == "Overplay" {
                record("playlist", "id=\(playlist.id.rawValue) name=\(playlist.name)")
                var lookup = MusicLibraryRequest<Playlist>()
                lookup.filter(matching: \.id, equalTo: playlist.id)
                let lookedUp = try await lookup.response()
                record("native playlist lookup", lookedUp.items.map { "id=\($0.id.rawValue) name=\($0.name)" }.joined(separator: "\n"))
                let detailed = try await playlist.with(.entries)
                var batch = detailed.entries
                var count = 0
                var resolvedLibraryIDs: [String] = []
                var resolvedCatalogCount = 0
                var resolutionFailures = 0
                let started = Date()
                repeat {
                    guard let current = batch else { break }
                    count += current.count
                    for entry in current {
                        if case .song(let song) = entry.item, cases.contains(where: { $0.title == song.title }) {
                            record("playlist entry", "entryID=\(entry.id.rawValue) position=\(entry.position) \(describe(song))")
                        }
                        if case .song(let song) = entry.item {
                            do {
                                switch try await MusicLibrarySongResolver.resolve(song.id) {
                                case .library(let resolved): resolvedLibraryIDs.append(resolved.id.rawValue)
                                case .catalog: resolvedCatalogCount += 1
                                }
                            } catch {
                                resolutionFailures += 1
                                record("resolution failed", "id=\(song.id.rawValue) \(error)")
                            }
                        }
                    }
                    batch = current.hasNextBatch ? try await current.nextBatch(limit: 100) : nil
                } while batch != nil
                record("playlist total", String(count))
                record("shared resolver full playlist", "library=\(resolvedLibraryIDs.count) catalog=\(resolvedCatalogCount) failures=\(resolutionFailures) duration=\(Date().timeIntervalSince(started))s")
                await verifyLibraryResources(resolvedLibraryIDs)
            }
        } catch { record("playlist error", String(describing: error)) }

        for sample in cases {
            for id in [sample.library, sample.numeric] {
                do {
                    var request = MusicLibraryRequest<Song>()
                    request.filter(matching: \.id, equalTo: MusicItemID(id))
                    let response = try await request.response()
                    record("native song id=\(id)", response.items.map(describe).joined(separator: "\n") + "\ncount=\(response.items.count)")
                } catch { record("native song error id=\(id)", String(describing: error)) }
                await rest(path: "/v1/me/library/songs", query: ["ids": id, "include": "catalog"])
            }
        }
        record("complete", "No sync, persistence reads/writes, player, or remote library mutations were performed. Only this report was saved.")
    }

    private func verifyLibraryResources(_ ids: [String]) async {
        let unique = Array(Set(ids)).sorted()
        var verified: Set<String> = []
        do {
            for start in stride(from: 0, to: unique.count, by: 25) {
                let batch = Array(unique[start..<min(start + 25, unique.count)])
                var url = URLComponents(string: "https://api.music.apple.com/v1/me/library/songs")!
                url.queryItems = [URLQueryItem(name: "ids", value: batch.joined(separator: ",")), URLQueryItem(name: "include", value: "catalog")]
                let response = try await MusicDataRequest(urlRequest: URLRequest(url: url.url!)).response()
                let envelope = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
                for resource in envelope?["data"] as? [[String: Any]] ?? [] {
                    guard let id = resource["id"] as? String, resource["type"] as? String == "library-songs",
                          let relationships = resource["relationships"] as? [String: Any],
                          let catalog = relationships["catalog"] as? [String: Any],
                          catalog["data"] is [Any], catalog["next"] == nil else { continue }
                    verified.insert(id)
                }
            }
            record("full playlist web identity verification", "requestedUnique=\(unique.count) verified=\(verified.count) missing=\(Set(unique).subtracting(verified).sorted())")
        } catch { record("full playlist verification error", String(describing: error)) }
    }

    private func rest(path: String, query: [String: String]) async {
        var components = URLComponents(string: "https://api.music.apple.com")!
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let label = "GET \(components.url!.absoluteString)"
        do {
            let response = try await MusicDataRequest(urlRequest: URLRequest(url: components.url!)).response()
            // Keep IDs and documented relationship fields, omit artwork URLs,
            // playback parameters, tokens, and unrelated account/library data.
            let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
            let filtered = sanitize(object)
            let data = try JSONSerialization.data(withJSONObject: filtered, options: [.prettyPrinted, .sortedKeys])
            record(label, String(decoding: data, as: UTF8.self))
        } catch { record(label, "ERROR \(error)") }
    }

    private func sanitize(_ object: [String: Any]) -> [String: Any] {
        let keys: Set<String> = ["data", "id", "type", "attributes", "relationships", "catalog", "name", "artistName", "albumName", "durationInMillis", "isrc", "next", "errors", "code", "title", "detail", "status"]
        return object.reduce(into: [:]) { result, pair in
            guard keys.contains(pair.key) else { return }
            if let dictionary = pair.value as? [String: Any] { result[pair.key] = sanitize(dictionary) }
            else if let array = pair.value as? [[String: Any]] { result[pair.key] = array.map(sanitize) }
            else { result[pair.key] = pair.value }
        }
    }
}
