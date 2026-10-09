import Foundation

/// Every distinct way Overplay touches Apple Music's out-of-process
/// services: the MusicKit request APIs, the shared library, the shared
/// application player, and the CarPlay templates. Overplay writes no system
/// Now Playing and registers no remote commands (`PLAY-016`).
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
    case recentlyPlayedQuery
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
    case playerPrepare
    case playerPlay
    case playerPause
    case playerSkipNext
    case playerSkipPrevious
    case playerSkipToEntry
    /// Any shuffle or repeat write, whichever surface asked for it.
    case playerModeReset
    case playbackRecoveryAttempt

    // Overplay's own playback decisions. Not Apple Music calls, but they
    // cause the calls above, and diagnosing a failure from the call log
    // alone means guessing at them.
    /// The player reported an entry Overplay could not attribute to the
    /// playback intent (`PLAY-011`). The raw value predates the removal of
    /// queue correlation; it is kept so retained logs still decode.
    case queueCorrelationRejected
    case deliveryStallDetected
    case queueEndObserved
    /// A shuffle or repeat change Overplay noticed rather than made — the only
    /// evidence that another surface touched the modes.
    case playerModeObserved
    case playbackQueueInvalidation
    case playbackStateInvalidation
    case playbackQueueObservationRebound
    case playbackObservationCoalesced
    case playCountLookupResult
    /// A player call Overplay is about to wait on. Its completion is listed
    /// under the call's own operation, so a start with no completion is a
    /// call that never returned (#84).
    case playerCallStarted
    /// An entry change the controller handled: the reported item, the intent
    /// member it was attributed to, and how (#84).
    case playerEntryObserved
    /// The track every Overplay surface shows changed (#84).
    case nowPlayingDisplayChanged
    /// Player observation set aside while a start loads its queue (#76),
    /// listed once per start (#84).
    case observationHeld


    // Local performance work; distinct from Apple Music API calls.
    case artworkMemoryHit
    case artworkDiskHit
    case artworkDecode
    case artworkWorkWait
    case artworkCacheWrite
    case artworkRequestCoalesced
    case artworkRetrySkipped
    case playCountRefresh
    case playCountApply
    case playCountEvidenceRead
    case playCountRefreshSkipped
    case playCountDiscovery
    case playbackSelectionPath
    case playbackQueuePreparation
    case playlistPresentation
    case artworkThemeGeneration
    case artworkThemePersistence
    case videoCleanup

    // System media surfaces.
    /// CarPlay replaced the Now Playing action array. Recorded separately
    /// from mode publication so a visual reset can be correlated with a track
    /// transition even when MusicKit's shuffle mode never changed.
    case carPlayNowPlayingButtonsUpdate
    case carPlayRefreshRequested
    case carPlayListMutation
    case carPlayArtworkUpdate
    case carPlayNowPlayingButtonState

    // Artwork asset downloads from Apple's image CDN.
    case artworkDownload

    enum Category: String, Codable, Sendable, CaseIterable {
        case read
        case libraryWrite
        case player
        case systemMediaSurface
        case asset
        case playbackDecision
        case performance

        var title: String {
            switch self {
            case .read: "Catalog and library reads"
            case .libraryWrite: "Apple Music library writes"
            case .player: "Shared player commands"
            case .systemMediaSurface: "System media surfaces"
            case .asset: "Artwork downloads"
            case .playbackDecision: "Overplay playback decisions"
            case .performance: "Local performance"
            }
        }
    }

    var category: Category {
        switch self {
        case .artworkMemoryHit, .artworkDiskHit, .artworkDecode, .artworkWorkWait, .artworkCacheWrite, .artworkRequestCoalesced, .artworkRetrySkipped, .playCountRefresh, .playCountApply, .playCountEvidenceRead, .playCountRefreshSkipped, .playCountDiscovery, .playbackSelectionPath, .playbackQueuePreparation, .playlistPresentation, .artworkThemeGeneration, .artworkThemePersistence, .videoCleanup:
            .performance
        case .libraryPlaylistEnumeration, .libraryPlaylistLookup, .playlistTrackFetch,
             .catalogSearch, .catalogResourceFetch, .libraryTrackQuery, .recentlyPlayedQuery, .subscriptionCheck,
             .authorizationRequest:
            .read
        case .libraryPlaylistCreate, .libraryPlaylistEdit, .libraryPlaylistAddItem:
            .libraryWrite
        case .queueReplace, .playerPrepare, .playerPlay, .playerPause,
             .playerSkipNext, .playerSkipPrevious, .playerSkipToEntry, .playerModeReset,
             .playbackRecoveryAttempt:
            .player
        case .carPlayNowPlayingButtonsUpdate, .carPlayRefreshRequested, .carPlayListMutation, .carPlayArtworkUpdate, .carPlayNowPlayingButtonState:
            .systemMediaSurface
        case .artworkDownload:
            .asset
        case .queueCorrelationRejected, .deliveryStallDetected,
             .queueEndObserved, .playerModeObserved,
             .playbackQueueInvalidation, .playbackStateInvalidation, .playbackQueueObservationRebound,
             .playbackObservationCoalesced, .playCountLookupResult,
             .playerCallStarted, .playerEntryObserved, .nowPlayingDisplayChanged, .observationHeld:
            .playbackDecision
        }
    }

    var title: String {
        switch self {
        case .artworkMemoryHit: "Artwork memory hit"
        case .artworkDiskHit: "Artwork disk hit"
        case .artworkDecode: "Artwork decode"
        case .artworkWorkWait: "Artwork work wait"
        case .artworkCacheWrite: "Artwork cache write"
        case .artworkRequestCoalesced: "Artwork request coalesced"
        case .artworkRetrySkipped: "Artwork retry skipped"
        case .playCountRefresh: "Play count refresh"
        case .playCountApply: "Play count apply"
        case .playCountEvidenceRead: "Play count evidence read"
        case .playCountRefreshSkipped: "Play count refresh skipped"
        case .playCountDiscovery: "Play count discovery"
        case .playbackSelectionPath: "Playback selection path"
        case .playbackQueuePreparation: "Playback queue preparation"
        case .playlistPresentation: "Playlist presentation"
        case .artworkThemeGeneration: "Artwork theme generation"
        case .artworkThemePersistence: "Artwork theme persistence"
        case .videoCleanup: "Video cleanup"

        case .libraryPlaylistEnumeration: "Library playlist enumeration"
        case .libraryPlaylistLookup: "Library playlist lookup by id"
        case .playlistTrackFetch: "Playlist track fetch"
        case .catalogSearch: "Catalog search"
        case .catalogResourceFetch: "Catalog resource fetch"
        case .libraryTrackQuery: "Library track query"
        case .recentlyPlayedQuery: "Recently played songs query"
        case .playCountLookupResult: "Apple play count lookup result"
        case .subscriptionCheck: "Subscription check"
        case .authorizationRequest: "Authorization request"
        case .queueCorrelationRejected: "Unattributed player entry"
        case .deliveryStallDetected: "Delivery stall detected"
        case .queueEndObserved: "Queue end observed"
        case .playerModeObserved: "Playback mode changed elsewhere"
        case .playbackQueueInvalidation: "Player queue invalidation"
        case .playbackStateInvalidation: "Player state invalidation"
        case .playbackQueueObservationRebound: "Player queue observation rebound"
        case .playbackObservationCoalesced: "Player invalidation coalesced"
        case .playerCallStarted: "Player call started"
        case .playerEntryObserved: "Player entry handled"
        case .nowPlayingDisplayChanged: "Now Playing display changed"
        case .observationHeld: "Observation held during start"

        case .libraryPlaylistCreate: "Playlist create"
        case .libraryPlaylistEdit: "Playlist rewrite"
        case .libraryPlaylistAddItem: "Playlist add item"
        case .queueReplace: "Queue replace"
        case .playerPrepare: "Player prepare"
        case .playerPlay: "Player play"
        case .playerPause: "Player pause"
        case .playerSkipNext: "Player skip next"
        case .playerSkipPrevious: "Player skip previous"
        case .playerSkipToEntry: "Player skip to entry"
        case .playerModeReset: "Player mode write"
        case .playbackRecoveryAttempt: "Recovery attempt (user Play)"
        case .carPlayNowPlayingButtonsUpdate: "CarPlay Now Playing buttons update"
        case .carPlayRefreshRequested: "CarPlay refresh requested"
        case .carPlayListMutation: "CarPlay list mutation"
        case .carPlayArtworkUpdate: "CarPlay artwork update"
        case .carPlayNowPlayingButtonState: "CarPlay button availability"
        case .artworkDownload: "Artwork download"
        }
    }

    /// Operations that fire fast enough to flood a bounded event list — player
    /// invalidations and per-track artwork fetches. Mode writes are listed:
    /// they are rare, and their loaded count matters (#76). They are always
    /// counted, but only listed individually when they fail or carry a note.
    var isHighFrequency: Bool {
        if category == .performance {
            return self != .playbackSelectionPath
        }
        return switch self {
        case .artworkDownload,
             .playbackQueueInvalidation, .playbackStateInvalidation, .playbackObservationCoalesced:
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

/// Which surface asked for the command being recorded.
///
/// The single most useful thing missing from a call log after the fact is
/// whether a burst of retries came from the user, another playback surface,
/// or Overplay retrying itself.
/// No origin means Overplay's own UI. Every other initiator tags itself, so
/// the absence is meaningful rather than merely unknown — but only for as
/// long as that stays true, which is why each is set at a single choke point.
nonisolated enum MusicKitActivityOrigin: String, Codable, Equatable, Sendable {
    case carPlay
    case remoteCommand
    /// Overplay acting without anyone asking: the end-of-playlist rebuild and
    /// delivery-stall recovery. The shape most worth telling apart from a
    /// user retrying.
    case automatic

    var title: String {
        switch self {
        case .carPlay: "CarPlay"
        case .remoteCommand: "remote command"
        case .automatic: "automatic"
        }
    }
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
    /// Nil for calls Overplay makes without a surface asking, and for events
    /// recorded before origins were tracked.
    var origin: MusicKitActivityOrigin?
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
        origin: MusicKitActivityOrigin? = nil,
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
        self.origin = origin
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
    var timedCount: Int? = nil
    var totalDurationMilliseconds: Double? = nil
    var maximumDurationMilliseconds: Double? = nil

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

    init(tallies: [MusicKitActivityTally] = [], events: [MusicKitActivityEvent] = [], observationStartedAt: Date? = nil) {
        self.tallies = tallies
        self.events = events
        self.observationStartedAt = observationStartedAt
    }

    /// A retained log can name operations a later build removed. Only those
    /// entries are dropped; the rest of the history survives.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tallies = try container.decodeIfPresent([Retained<MusicKitActivityTally>].self, forKey: .tallies)?
            .compactMap(\.value) ?? []
        events = try container.decodeIfPresent([Retained<MusicKitActivityEvent>].self, forKey: .events)?
            .compactMap(\.value) ?? []
        observationStartedAt = try container.decodeIfPresent(Date.self, forKey: .observationStartedAt)
    }

    private struct Retained<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}
