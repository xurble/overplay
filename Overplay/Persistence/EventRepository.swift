import Foundation
import SwiftData

enum EventRepository {
    static func log(
        trackID: String,
        eventType: String,
        positionSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        progressPercentage: Double? = nil,
        reason: String? = nil,
        in context: ModelContext
    ) {
        let event = PlaybackEvent(
            trackID: trackID,
            eventType: eventType,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            progressPercentage: progressPercentage,
            reason: reason
        )
        context.insert(event)
    }
}
