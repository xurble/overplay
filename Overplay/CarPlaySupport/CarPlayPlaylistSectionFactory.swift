import CarPlay
import UIKit

/// Shared layout for One True Playlist, Triage, and Retired track lists.
@MainActor
enum CarPlayPlaylistSectionFactory {
    static func sections(
        trackItems: [CPListItem],
        scope: PlaylistPlaybackScope,
        shuffleAndPlay: @escaping @MainActor (PlaylistPlaybackScope) async -> Void
    ) -> [CPListSection] {
        let canPlay = !trackItems.isEmpty
        let shuffle = CPListItem(
            text: "Shuffle and Play",
            detailText: nil,
            image: UIImage(systemName: "shuffle")
        )
        shuffle.isEnabled = canPlay
        shuffle.handler = { _, completion in
            Task { @MainActor in
                defer { completion() }
                guard canPlay else { return }
                await shuffleAndPlay(scope)
            }
        }

        let contents: [CPListItem]
        if canPlay {
            contents = trackItems
        } else {
            let empty = CPListItem(text: "No playable tracks", detailText: "Sync this playlist in Overplay.")
            empty.isEnabled = false
            contents = [empty]
        }
        return [CPListSection(items: [shuffle]), CPListSection(items: contents)]
    }
}
