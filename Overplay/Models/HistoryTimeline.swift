import Foundation

enum HistoryEventFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case evictions
    case removals
    case promotions
    case restores
    case remoteMutations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            "All"
        case .evictions:
            "Evictions"
        case .removals:
            "Removals"
        case .promotions:
            "Promotions"
        case .restores:
            "Restores"
        case .remoteMutations:
            "Remote Mutations"
        }
    }

    func includes(_ event: HistoryEvent) -> Bool {
        switch self {
        case .all:
            true
        case .evictions:
            event.eventType == .evicted
        case .removals:
            event.eventType == .trackRemoved || event.eventType == .playlistRemoved
        case .promotions:
            event.eventType == .promoted
        case .restores:
            event.eventType == .restored
        case .remoteMutations:
            event.eventType == .remoteMutation || event.remoteMutationStatus != nil
        }
    }
}

struct HistoryEventRowModel: Identifiable, Equatable {
    var id: UUID
    var eventID: UUID
    var playlistID: UUID?
    var trackID: UUID?
    var eventType: HistoryEventType
    var eventTitle: String
    var sourceTitle: String
    var trackTitle: String
    var subtitle: String
    var message: String?
    var skipCountText: String?
    var remoteMutationStatusText: String?
    var artworkURLTemplate: String?
    var createdAt: Date
    var systemImage: String
}

enum HistoryTimeline {
    static func rows(
        events: [HistoryEvent],
        playlists: [PlaylistRecord],
        tracks: [TrackRecord],
        filter: HistoryEventFilter = .all
    ) -> [HistoryEventRowModel] {
        let playlistsByID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        return events
            .filter { filter.includes($0) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt > rhs.createdAt
            }
            .map { event in
                let playlist = event.playlistID.flatMap { playlistsByID[$0] }
                let track = event.trackID.flatMap { tracksByID[$0] }

                return HistoryEventRowModel(
                    id: event.id,
                    eventID: event.id,
                    playlistID: event.playlistID,
                    trackID: event.trackID,
                    eventType: event.eventType,
                    eventTitle: event.eventType.displayTitle,
                    sourceTitle: event.source.displayTitle,
                    trackTitle: track?.title ?? "Unknown Track",
                    subtitle: subtitle(track: track, playlist: playlist),
                    message: event.message,
                    skipCountText: event.skipCountAtEvent.map { "\($0) skips" },
                    remoteMutationStatusText: event.remoteMutationStatus?.displayTitle,
                    artworkURLTemplate: track?.artworkURLTemplate,
                    createdAt: event.createdAt,
                    systemImage: event.eventType.systemImage
                )
            }
    }

    private static func subtitle(track: TrackRecord?, playlist: PlaylistRecord?) -> String {
        let artist = track?.artistName
        let playlistName = playlist?.name

        switch (artist?.isEmpty == false ? artist : nil, playlistName?.isEmpty == false ? playlistName : nil) {
        case let (.some(artist), .some(playlistName)):
            return "\(artist) - \(playlistName)"
        case let (.some(artist), .none):
            return artist
        case let (.none, .some(playlistName)):
            return playlistName
        case (.none, .none):
            return "No playlist context"
        }
    }
}

extension HistoryEventType {
    var displayTitle: String {
        switch self {
        case .playlistLinked:
            "Playlist Linked"
        case .playlistUpdated:
            "Playlist Updated"
        case .playlistRemoved:
            "Playlist Removed"
        case .trackAdded:
            "Added"
        case .trackRemoved:
            "Removed"
        case .skipIgnored:
            "Skip Ignored"
        case .skipCounted:
            "Skip Counted"
        case .playthrough:
            "Playthrough"
        case .evicted:
            "Evicted"
        case .restored:
            "Restored"
        case .promoted:
            "Promoted"
        case .remoteMutation:
            "Remote Mutation"
        }
    }

    var systemImage: String {
        switch self {
        case .playlistLinked, .playlistUpdated:
            "music.note.list"
        case .playlistRemoved, .trackRemoved:
            "xmark.circle.fill"
        case .trackAdded:
            "plus.circle.fill"
        case .skipIgnored:
            "forward.end"
        case .skipCounted:
            "forward.end.fill"
        case .playthrough:
            "checkmark.circle.fill"
        case .evicted:
            "trash.fill"
        case .restored:
            "arrow.uturn.backward.circle.fill"
        case .promoted:
            "star.fill"
        case .remoteMutation:
            "arrow.triangle.2.circlepath"
        }
    }
}

extension HistoryEventSource {
    var displayTitle: String {
        switch self {
        case .user:
            "Manual"
        case .playback:
            "Playback"
        case .sync:
            "Sync"
        case .appleMusic:
            "Apple Music"
        case .overplay:
            "Overplay"
        }
    }
}

extension RemoteMutationStatus {
    var displayTitle: String {
        switch self {
        case .notAttempted:
            "Remote not attempted"
        case .pending:
            "Remote pending"
        case .succeeded:
            "Remote succeeded"
        case .failed:
            "Remote failed"
        case .unsupported:
            "Remote unsupported"
        }
    }
}
