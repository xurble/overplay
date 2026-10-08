#if targetEnvironment(simulator)
import Foundation
import SwiftData

/// A sample library for the simulator, where there is no Apple Music library
/// or iCloud data: enough playlists, Triage and Retired songs to exercise
/// navigation and layout. Seeded only into the empty local simulator store
/// (`AppPersistence`). A copy of a real device store placed there instead is
/// left alone, which also brings its artwork links.
enum SimulatorDemoLibrary {
    static func seedIfEmpty(_ context: ModelContext) {
        guard (try? LibraryRestorationService.isEmpty(in: context)) == true else { return }

        let otp = PlaylistRecord(musicPlaylistID: "p.simulator-overplay", name: "Overplay", role: .oneTruePlaylist)
        let bucket = PlaylistRecord(
            musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
            name: PlaylistRecord.triageBucketName, role: .triageBucket, writePolicy: .incomingOnly
        )
        let source = PlaylistRecord(musicPlaylistID: "p.simulator-new-music", name: "New Music Mix", role: .triageSource)
        let settings = OverplaySettings(selectedPlaylistID: otp.musicPlaylistID, selectedPlaylistName: otp.name)
        [otp, bucket, source].forEach(context.insert)
        context.insert(settings)

        let artists = ["Electronic", "Massive Attack", "Arctic Monkeys", "Kate Bush", "The Streets", "Saint Etienne"]
        func track(_ index: Int, _ title: String) -> TrackRecord {
            let track = TrackRecord(
                catalogID: "sim-\(index)", libraryID: "i.sim-\(index)", title: title,
                artistName: artists[index % artists.count], albumTitle: "Sample Album \(index % 5 + 1)",
                durationSeconds: Double(180 + index * 7 % 120)
            )
            context.insert(track)
            return track
        }

        let otpTitles = ["Getting Away with It", "Not Sleeping Around", "Teardrop", "Mardy Bum", "Running Up That Hill",
                         "Dry Your Eyes", "He's on the Phone", "Get the Message", "Angel", "505", "Cloudbusting", "Fit But You Know It"]
        for (index, title) in otpTitles.enumerated() {
            context.insert(PlaylistItemRecord(
                playlistID: otp.id, trackID: track(index, title).id, sortOrder: index,
                skipCount: index % 3, playthroughCount: index * 2 % 7, lastSeenInPlaylistAt: .now
            ))
        }

        let triageTitles = ["Kiss of Life", "Inertia Creeps", "Fluorescent Adolescent", "Hounds of Love",
                            "Blinded by the Lights", "Like a Motorway", "Unfinished Sympathy", "Wuthering Heights"]
        for (offset, title) in triageTitles.enumerated() {
            let index = otpTitles.count + offset
            let retired = offset >= triageTitles.count - 3
            context.insert(PlaylistItemRecord(
                playlistID: bucket.id, trackID: track(index, title).id,
                sourceMusicPlaylistIDs: [source.musicPlaylistID], sortOrder: offset,
                skipCount: retired ? 2 : 0, lastSeenInPlaylistAt: .now,
                evictedAt: retired ? .now : nil,
                evictionReason: retired ? .manual : nil,
                evictionSource: retired ? .user : nil
            ))
        }
        try? context.save()
    }
}
#endif
