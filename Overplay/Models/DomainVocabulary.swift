enum PlaylistSource: String, CaseIterable, Codable, Hashable, Sendable {
    case appleMusic
}

enum PlaylistRole: String, CaseIterable, Codable, Hashable, Sendable {
    case oneTruePlaylist
    case triage
}

enum PlaylistWritePolicy: String, CaseIterable, Codable, Hashable, Sendable {
    case managed
    case incomingOnly
}

enum HistoryEventType: String, CaseIterable, Codable, Hashable, Sendable {
    case playlistLinked
    case playlistUpdated
    case playlistRemoved
    case trackAdded
    case trackRemoved
    case skipIgnored
    case skipCounted
    case playthrough
    case evicted
    case restored
    case promoted
    case remoteMutation
}

enum HistoryEventSource: String, CaseIterable, Codable, Hashable, Sendable {
    case user
    case playback
    case sync
    case appleMusic
    case overplay
    /// Counted retroactively by suspended-playback reconciliation rather
    /// than witnessed live.
    case reconciled
}

enum EvictionReason: String, CaseIterable, Codable, Hashable, Sendable {
    case skipCount
    case manual
    case remoteRemoval
}

enum EvictionSource: String, CaseIterable, Codable, Hashable, Sendable {
    case user
    case playbackRule
    case appleMusicSync
}

enum RemoteMutationStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case notAttempted
    case pending
    case succeeded
    case failed
    case unsupported
}
