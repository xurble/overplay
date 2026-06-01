import Foundation
import SwiftData

enum EventRepository {
    @discardableResult
    static func logHistory(
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
        in context: ModelContext
    ) -> HistoryEvent {
        let event = HistoryEvent(
            playlistID: playlistID,
            trackID: trackID,
            eventType: eventType,
            source: source,
            skipCountAtEvent: skipCountAtEvent,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            progressPercentage: progressPercentage,
            remoteMutationStatus: remoteMutationStatus,
            message: message
        )
        context.insert(event)
        return event
    }
}
