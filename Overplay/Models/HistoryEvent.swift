import Foundation
import SwiftData

@Model
final class HistoryEvent {
    var id: UUID = UUID()
    var playlistID: UUID?
    var trackID: UUID?
    var eventType: HistoryEventType = HistoryEventType.remoteMutation
    var source: HistoryEventSource = HistoryEventSource.overplay
    var skipCountAtEvent: Int?
    var positionSeconds: Double?
    var durationSeconds: Double?
    var progressPercentage: Double?
    var remoteMutationStatus: RemoteMutationStatus?
    var message: String?
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        playlistID: UUID? = nil,
        trackID: UUID? = nil,
        eventType: HistoryEventType,
        source: HistoryEventSource,
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
        self.eventType = eventType
        self.source = source
        self.skipCountAtEvent = skipCountAtEvent
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.progressPercentage = progressPercentage
        self.remoteMutationStatus = remoteMutationStatus
        self.message = message
        self.createdAt = createdAt
    }
}
