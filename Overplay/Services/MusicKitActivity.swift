import Foundation

/// Every distinct way Overplay touches Apple Music's out-of-process
/// services: the MusicKit request APIs, the shared library, the shared
/// application player, and the system media surfaces (`MPNowPlayingInfoCenter`
/// and `MPRemoteCommandCenter`).
///
/// These are the only calls that can plausibly overload Apple Music, so each
/// one is recorded through `MusicKitActivityLog` and summarised by
/// `MusicKitActivityReport`.
nonisolated enum MusicKitActivityOperation: String, Codable, CaseIterable, Sendable {
    // Catalog and library reads.
    case libraryPlaylistEnumeration
    case libraryPlaylistLookup
    case playlistTrackFetch
    case catalogSearch
    case catalogResourceFetch
    case libraryTrackQuery
    case subscriptionCheck
    case authorizationRequest

    // Library writes. These mutate the user's Apple Music library and sync
    // through iCloud Music Library, so they are the most expensive calls
    // Overplay can make.
    case libraryPlaylistCreate
    case libraryPlaylistEdit
    case libraryPlaylistAddItem

    // Shared application player commands.
    case queueReplace
    case queueAppend
    case playerPrepare
    case playerPlay
    case playerPause
    case playerSkipNext
    case playerSkipPrevious
    case playerSkipToEntry
    case playerModeReset
    case playbackRecoveryAttempt

    // System media surfaces.
    case nowPlayingInfoWrite
    case nowPlayingInfoWriteWhilePaused
    case nowPlayingInfoClear
    case remoteCommandReceived

    // Artwork asset downloads from Apple's image CDN.
    case artworkDownload

    enum Category: String, Codable, Sendable, CaseIterable {
        case read
        case libraryWrite
        case player
        case systemMediaSurface
        case asset

        var title: String {
            switch self {
            case .read: "Catalog and library reads"
            case .libraryWrite: "Apple Music library writes"
            case .player: "Shared player commands"
            case .systemMediaSurface: "System media surfaces"
            case .asset: "Artwork downloads"
            }
        }
    }

    var category: Category {
        switch self {
        case .libraryPlaylistEnumeration, .libraryPlaylistLookup, .playlistTrackFetch,
             .catalogSearch, .catalogResourceFetch, .libraryTrackQuery, .subscriptionCheck,
             .authorizationRequest:
            .read
        case .libraryPlaylistCreate, .libraryPlaylistEdit, .libraryPlaylistAddItem:
            .libraryWrite
        case .queueReplace, .queueAppend, .playerPrepare, .playerPlay, .playerPause,
             .playerSkipNext, .playerSkipPrevious, .playerSkipToEntry, .playerModeReset,
             .playbackRecoveryAttempt:
            .player
        case .nowPlayingInfoWrite, .nowPlayingInfoWriteWhilePaused, .nowPlayingInfoClear,
             .remoteCommandReceived:
            .systemMediaSurface
        case .artworkDownload:
            .asset
        }
    }

    var title: String {
        switch self {
        case .libraryPlaylistEnumeration: "Library playlist enumeration"
        case .libraryPlaylistLookup: "Library playlist lookup by id"
        case .playlistTrackFetch: "Playlist track fetch"
        case .catalogSearch: "Catalog search"
        case .catalogResourceFetch: "Catalog resource fetch"
        case .libraryTrackQuery: "Library track query"
        case .subscriptionCheck: "Subscription check"
        case .authorizationRequest: "Authorization request"
        case .libraryPlaylistCreate: "Playlist create"
        case .libraryPlaylistEdit: "Playlist rewrite"
        case .libraryPlaylistAddItem: "Playlist add item"
        case .queueReplace: "Queue replace"
        case .queueAppend: "Queue append"
        case .playerPrepare: "Player prepare"
        case .playerPlay: "Player play"
        case .playerPause: "Player pause"
        case .playerSkipNext: "Player skip next"
        case .playerSkipPrevious: "Player skip previous"
        case .playerSkipToEntry: "Player skip to entry"
        case .playerModeReset: "Player mode reset"
        case .playbackRecoveryAttempt: "Automatic delivery recovery"
        case .nowPlayingInfoWrite: "Now Playing write (playing)"
        case .nowPlayingInfoWriteWhilePaused: "Now Playing write (not playing)"
        case .nowPlayingInfoClear: "Now Playing clear"
        case .remoteCommandReceived: "Remote command received"
        case .artworkDownload: "Artwork download"
        }
    }

    /// Operations that fire fast enough to flood a bounded event list — the
    /// 1 Hz monitor writes and per-track artwork fetches. They are always
    /// counted, but only listed individually when they fail or carry a note.
    var isHighFrequency: Bool {
        switch self {
        case .nowPlayingInfoWrite, .nowPlayingInfoWriteWhilePaused, .nowPlayingInfoClear,
             .playerModeReset, .artworkDownload:
            true
        default:
            false
        }
    }

    /// Whether a write reaches the user's Apple Music library rather than
    /// only Overplay's own process or the local player.
    var mutatesAppleMusicLibrary: Bool {
        category == .libraryWrite
    }
}

/// A qualifier attached to a recorded call. Notes exist for the patterns
/// worth flagging even when the call itself succeeded.
nonisolated enum MusicKitActivityNote: String, Codable, Sendable {
    /// A paginated MusicKit collection reported more batches that Overplay
    /// did not fetch, so the returned items are incomplete.
    case truncatedCollection
    /// Overplay issued the call by itself, without a user action — the shape
    /// that can become a retry storm.
    case automaticRetry
    /// The call was initiated by an external surface (Lock Screen, Control
    /// Center, CarPlay, AirPods, media keys) rather than Overplay's own UI.
    case externalSurface
}

nonisolated struct MusicKitActivityEvent: Codable, Equatable, Sendable {
    var operation: MusicKitActivityOperation
    var startedAt: Date
    var durationMilliseconds: Double?
    /// A size for the call: queue entries handed over, items returned,
    /// pages fetched. Lets the report threshold on magnitude without
    /// parsing free text.
    var magnitude: Double?
    var detail: String?
    var notes: [MusicKitActivityNote]
    var errorDomain: String?
    var errorCode: Int?
    var errorDescription: String?

    init(
        operation: MusicKitActivityOperation,
        startedAt: Date,
        durationMilliseconds: Double? = nil,
        magnitude: Double? = nil,
        detail: String? = nil,
        notes: [MusicKitActivityNote] = [],
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        errorDescription: String? = nil
    ) {
        self.operation = operation
        self.startedAt = startedAt
        self.durationMilliseconds = durationMilliseconds
        self.magnitude = magnitude
        self.detail = detail
        self.notes = notes
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.errorDescription = errorDescription
    }

    var didFail: Bool { errorDomain != nil }
}

/// One minute of activity for one operation. Counting into minute buckets
/// keeps exact rate windows (and a maximum magnitude) in a few bytes per
/// minute, so the report can answer "how many calls in the last five
/// minutes" without retaining every call.
nonisolated struct MusicKitActivityTally: Codable, Equatable, Sendable {
    var minute: Int
    var operation: MusicKitActivityOperation
    var count: Int
    var failureCount: Int
    var maximumMagnitude: Double?

    static func minuteIndex(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    var startDate: Date {
        Date(timeIntervalSince1970: Double(minute) * 60)
    }
}

nonisolated struct MusicKitActivitySnapshot: Codable, Equatable, Sendable {
    var tallies: [MusicKitActivityTally] = []
    var events: [MusicKitActivityEvent] = []
    var observationStartedAt: Date?
}
