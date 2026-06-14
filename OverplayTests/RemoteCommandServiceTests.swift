import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Remote command service")
struct RemoteCommandServiceTests {
    @Test("activate update and deactivate manage lifecycle state")
    func activateUpdateAndDeactivateManageLifecycleState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let firstContext = ModelContext(container)
        let secondContext = ModelContext(container)
        let playbackController = PlaybackController()
        let service = RemoteCommandService()

        service.activate(playbackController: playbackController, context: firstContext)
        let initialTargetCount = service.registeredTargetCount

        #expect(service.isActive)
        #expect(initialTargetCount == 7)
        #expect(service.context === firstContext)

        service.update(playbackController: playbackController, context: secondContext)

        #expect(service.isActive)
        #expect(service.registeredTargetCount == initialTargetCount)
        #expect(service.context === secondContext)

        service.deactivate()

        #expect(!service.isActive)
        #expect(service.registeredTargetCount == 0)
        #expect(service.context == nil)
        #expect(service.playbackController == nil)
    }

    @Test("repeated activation updates context without duplicate remote targets")
    func repeatedActivationUpdatesContextWithoutDuplicateRemoteTargets() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let firstContext = ModelContext(container)
        let carPlayContext = ModelContext(container)
        let playbackController = PlaybackController()
        let service = RemoteCommandService()

        service.activate(playbackController: playbackController, context: firstContext)
        let initialTargetCount = service.registeredTargetCount

        service.activate(playbackController: playbackController, context: carPlayContext)

        #expect(service.isActive)
        #expect(service.registeredTargetCount == initialTargetCount)
        #expect(service.context === carPlayContext)

        service.deactivate()
    }
}
