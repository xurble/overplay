import Foundation
import SwiftData

enum PreviewContainer {
    @MainActor
    static func make() -> ModelContainer {
        let schema = Schema([
            OverplaySettings.self,
            TrackedTrack.self,
            PlaybackEvent.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let settings = OverplaySettings(
            selectedPlaylistID: "preview-playlist",
            selectedPlaylistName: "Overplay"
        )
        context.insert(settings)
        context.insert(TrackedTrack(
            id: "preview-track",
            playlistID: "preview-playlist",
            title: "Glasshouse",
            artistName: "The Sample Set",
            albumTitle: "Overplay Sessions",
            durationSeconds: 214,
            skipCount: 2
        ))
        context.insert(TrackedTrack(
            id: "preview-evicted",
            playlistID: "preview-playlist",
            title: "Too Soon",
            artistName: "The Sample Set",
            durationSeconds: 186,
            skipCount: 3,
            evictedAt: .now,
            evictionReason: "3 skips before 50%"
        ))
        try? context.save()
        return container
    }
}
