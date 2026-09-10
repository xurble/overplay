import Foundation

struct PlaylistSummaryPresentation: Equatable, Identifiable, Sendable {
    enum IconIntent: Equatable, Sendable {
        case oneTruePlaylist
        case triageBucket
        case triageSource
        case retired
        case currentPlayback

        var systemImage: String {
            switch self {
            case .oneTruePlaylist:
                "star.fill"
            case .triageBucket:
                "tray.fill"
            case .triageSource:
                "music.note.list"
            case .retired:
                "archivebox.fill"
            case .currentPlayback:
                "play.fill"
            }
        }
    }

    let id: UUID
    var musicPlaylistID: String?
    let title: String
    var artworkURLString: String?
    let role: PlaylistRole
    let source: PlaylistSource
    let writePolicy: PlaylistWritePolicy
    let activeTrackCount: Int
    let playableTrackCount: Int
    let lastSyncedAt: Date?
    let isCurrentPlaybackPlaylist: Bool
    var playbackScope: PlaylistPlaybackScope = .active

    var roleTitle: String {
        if playbackScope == .retired { return "Retired" }
        return switch role {
        case .oneTruePlaylist:
            "One True Playlist"
        case .triageBucket:
            "Triage"
        case .triageSource:
            "Triage Source"
        }
    }

    var shortRoleTitle: String {
        switch role {
        case .oneTruePlaylist:
            "Main"
        case .triageBucket:
            "Triage"
        case .triageSource:
            "Source"
        }
    }

    var iconIntent: IconIntent {
        if isCurrentPlaybackPlaylist {
            return .currentPlayback
        }
        if playbackScope == .retired { return .retired }

        switch role {
        case .oneTruePlaylist:
            return .oneTruePlaylist
        case .triageBucket:
            return .triageBucket
        case .triageSource:
            return .triageSource
        }
    }

    var displayPriority: Int {
        switch role {
        case .oneTruePlaylist:
            0
        case .triageBucket:
            1
        case .triageSource:
            2
        }
    }

    var sourceTitle: String {
        switch source {
        case .appleMusic:
            "Apple Music"
        }
    }

    var writePolicyTitle: String {
        switch writePolicy {
        case .managed:
            "Managed"
        case .incomingOnly:
            "Incoming only"
        }
    }

    var activeTrackCountLabel: String {
        "\(activeTrackCount) tracks"
    }

    var playableTrackCountLabel: String {
        playableTrackCount == 1 ? "1 playable track" : "\(playableTrackCount) playable tracks"
    }

    var syncStatusLabel: String {
        lastSyncedAt.map { "Synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not synced"
    }

    var dashboardDetailText: String {
        "\(activeTrackCountLabel) - \(sourceTitle) - \(syncStatusLabel) - \(writePolicyTitle)"
    }

    static func areInDisplayOrder(_ left: PlaylistSummaryPresentation, _ right: PlaylistSummaryPresentation) -> Bool {
        if left.displayPriority != right.displayPriority {
            return left.displayPriority < right.displayPriority
        }

        return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }
}
