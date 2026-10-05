import Foundation
import SwiftData

enum ListenEventKind: String, Codable, CaseIterable, Sendable {
    case playthrough
    case skip
    /// Restarts one track's skip count from this moment.
    case skipReset
    /// Restarts every track's counts from this moment.
    case statsReset
    /// Counts carried forward from before the ledger existed.
    case baseline
    /// The track absorbed another track in an identity merge. The donor UUID
    /// is carried in the session ID (`lineage:<donor>`). Immutable, so two
    /// devices merging into the same keeper cannot lose each other's lineage.
    case lineage
}

enum ListenEventSource: String, Codable, Sendable {
    case playback
    case reconciled
    case migration
    case user
}

/// One counted listening outcome. Inserted once and never edited, so devices
/// and merges can only ever add evidence; counts are derived (`COUNT-002`).
@Model
final class LibraryListenV2 {
    #Index<LibraryListenV2>([\.trackID])

    var id: UUID = UUID()
    var trackID: UUID = UUID()
    var kindRawValue: String = ListenEventKind.playthrough.rawValue
    /// Two events with the same kind and session ID count once.
    var sessionID: String = ""
    var deviceID: String = ""
    var sourceRawValue: String = ListenEventSource.playback.rawValue
    var mechanismRawValue: String?
    var playthroughDelta: Int = 0
    var skipDelta: Int = 0
    var occurredAt: Date = Date()

    var kind: ListenEventKind? { ListenEventKind(rawValue: kindRawValue) }

    init(
        trackID: UUID,
        kind: ListenEventKind,
        sessionID: String,
        deviceID: String,
        source: ListenEventSource,
        mechanism: String? = nil,
        playthroughDelta: Int = 0,
        skipDelta: Int = 0,
        occurredAt: Date = .now
    ) {
        self.trackID = trackID
        self.kindRawValue = kind.rawValue
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.sourceRawValue = source.rawValue
        self.mechanismRawValue = mechanism
        self.playthroughDelta = playthroughDelta
        self.skipDelta = skipDelta
        self.occurredAt = occurredAt
    }
}

// Source-level name; storage identity is V2 like the rest of the graph.
typealias ListenEvent = LibraryListenV2
