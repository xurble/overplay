enum PlaylistSource: String, CaseIterable, Codable, Hashable, Sendable {
    case appleMusic
}

enum PlaylistRole: String, CaseIterable, Codable, Hashable, Sendable {
    case oneTruePlaylist
    /// The single shared triage bucket. It owns every triage item and has no
    /// Apple Music playlist of its own.
    case triageBucket
    /// An Apple Music playlist that contributes tracks to the bucket. Never
    /// played, and never presented as a top-level playlist.
    case triageSource

    /// The raw value stored before the bucket existed. `PlaylistRecord.role`
    /// resolves it to `.triageSource`, which is inert until the migration
    /// re-parents the playlist's items onto the bucket. Resolving it to
    /// `.triageBucket` instead would conjure a second bucket, so the
    /// recoverable direction is the deliberate one.
    nonisolated static let legacyTriageRawValue = "triage"
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

/// The evidence that allowed a suspended playthrough to be written after
/// Overplay resumed execution.
enum PlaybackReconciliationMechanism: String, CaseIterable, Codable, Hashable, Sendable {
    /// A player observation landed at or beyond the configured threshold.
    case pointObservation
    /// Elapsed wall time matched the durations and positions across a span.
    case wallClockContinuity
    /// Apple Music's play count and last-played date both advanced.
    case musicKitPlayCount
}

/// Why an item left a playlist. Eviction is a manual decision now, so the
/// only automatic reason left is Apple Music removing the track upstream.
enum EvictionReason: String, CaseIterable, Codable, Hashable, Sendable {
    case manual
    case remoteRemoval
}

enum EvictionSource: String, CaseIterable, Codable, Hashable, Sendable {
    case user
    case appleMusicSync
}

enum RemoteMutationStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case notAttempted
    case pending
    case succeeded
    case failed
    case unsupported
}
