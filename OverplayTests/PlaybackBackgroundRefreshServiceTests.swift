import BackgroundTasks
import Foundation
import Testing
@testable import Overplay

@MainActor
struct PlaybackBackgroundRefreshServiceTests {
    @Test("refresh re-arms before work and keeps fallback for a nil target or missing context")
    func fallbackBeforeWork() async {
        for missingContext in [false, true] {
            let now = Date()
            var requests: [BGAppRefreshTaskRequest] = []
            let service = PlaybackBackgroundRefreshService(submit: { requests.append($0) }, now: { now })
            let success = await service.performRefresh {
                #expect(requests.count == 1)
                #expect(requests.first?.earliestBeginDate == now.addingTimeInterval(900))
                return missingContext ? nil : .init()
            }
            #expect(success == !missingContext)
            #expect(requests.count == 1)
        }
    }

    @Test("expiration during suspended work leaves the replacement pending")
    func expiration() async {
        var requests: [BGAppRefreshTaskRequest] = []
        let service = PlaybackBackgroundRefreshService(submit: { requests.append($0) })
        let operation = Task { @MainActor in
            await service.performRefresh {
                #expect(requests.count == 1)
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(nextWakeTarget: Date().addingTimeInterval(60))
            }
        }
        #expect(await operation.value == false)
        #expect(requests.count == 1)
    }

    @Test("known target refines the fallback request")
    func knownTarget() async {
        var requests: [BGAppRefreshTaskRequest] = []
        let service = PlaybackBackgroundRefreshService(submit: { requests.append($0) })
        let target = Date().addingTimeInterval(120)
        let success = await service.performRefresh { .init(nextWakeTarget: target) }
        #expect(success)
        #expect(requests.count == 2)
        #expect(requests.last?.earliestBeginDate == target)
    }
}
