import SwiftData
import Testing
@testable import Overplay

@MainActor
enum OverplayTestSupport {
    static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            OverplaySettings.self,
            TrackedTrack.self,
            PlaybackEvent.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func playbackEvents(in context: ModelContext) throws -> [PlaybackEvent] {
        try context.fetch(FetchDescriptor<PlaybackEvent>())
    }
}
