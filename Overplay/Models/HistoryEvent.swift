import Foundation
import SwiftData

@Model
final class HistoryEvent {
    var id: UUID = UUID()
    var playlistID: UUID?
    var trackID: UUID?
    var eventTypeRawValue: String = HistoryEventType.remoteMutation.rawValue
    var sourceRawValue: String = HistoryEventSource.overplay.rawValue
    var reconciliationMechanismRawValue: String?
    var skipCountAtEvent: Int?
    var positionSeconds: Double?
    var durationSeconds: Double?
    var progressPercentage: Double?
    var remoteMutationStatusRawValue: String?
    var message: String?
    var createdAt: Date = Date()

    var eventType: HistoryEventType {
        get { HistoryEventType(rawValue: eventTypeRawValue) ?? .remoteMutation }
        set { eventTypeRawValue = newValue.rawValue }
    }

    var source: HistoryEventSource {
        get { HistoryEventSource(rawValue: sourceRawValue) ?? .overplay }
        set { sourceRawValue = newValue.rawValue }
    }

    var remoteMutationStatus: RemoteMutationStatus? {
        get { remoteMutationStatusRawValue.flatMap(RemoteMutationStatus.init(rawValue:)) }
        set { remoteMutationStatusRawValue = newValue?.rawValue }
    }

    var reconciliationMechanism: PlaybackReconciliationMechanism? {
        get { reconciliationMechanismRawValue.flatMap(PlaybackReconciliationMechanism.init(rawValue:)) }
        set { reconciliationMechanismRawValue = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        playlistID: UUID? = nil,
        trackID: UUID? = nil,
        eventType: HistoryEventType,
        source: HistoryEventSource,
        reconciliationMechanism: PlaybackReconciliationMechanism? = nil,
        skipCountAtEvent: Int? = nil,
        positionSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        progressPercentage: Double? = nil,
        remoteMutationStatus: RemoteMutationStatus? = nil,
        message: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.playlistID = playlistID
        self.trackID = trackID
        self.eventTypeRawValue = eventType.rawValue
        self.sourceRawValue = source.rawValue
        self.reconciliationMechanismRawValue = reconciliationMechanism?.rawValue
        self.skipCountAtEvent = skipCountAtEvent
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.progressPercentage = progressPercentage
        self.remoteMutationStatusRawValue = remoteMutationStatus?.rawValue
        self.message = message
        self.createdAt = createdAt
    }
}
