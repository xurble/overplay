import Foundation
import SwiftData

@Model
final class PlaybackEvent {
    var id: UUID = UUID()
    var trackID: String = ""
    var eventType: String = ""
    var positionSeconds: Double?
    var durationSeconds: Double?
    var progressPercentage: Double?
    var reason: String?
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        trackID: String,
        eventType: String,
        positionSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        progressPercentage: Double? = nil,
        reason: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.trackID = trackID
        self.eventType = eventType
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.progressPercentage = progressPercentage
        self.reason = reason
        self.createdAt = createdAt
    }
}
