import Testing
@testable import Overplay

@Suite("Track health status")
struct TrackHealthStatusTests {
    @Test("never skipped is healthy")
    func neverSkippedIsHealthy() {
        #expect(TrackHealthStatus.resolve(skipCount: 0, evictAfterSkips: 3, isEvicted: false, isProtected: false) == .healthy)
    }

    @Test("protected is always healthy")
    func protectedIsHealthy() {
        #expect(TrackHealthStatus.resolve(skipCount: 2, evictAfterSkips: 3, isEvicted: false, isProtected: true) == .healthy)
        #expect(TrackHealthStatus.resolve(skipCount: 2, evictAfterSkips: 3, isEvicted: true, isProtected: true) == .healthy)
    }

    @Test("evicted is critical")
    func evictedIsCritical() {
        #expect(TrackHealthStatus.resolve(skipCount: 0, evictAfterSkips: 3, isEvicted: true, isProtected: false) == .critical)
    }

    @Test("single skip with threshold three is caution")
    func singleSkipIsCaution() {
        #expect(TrackHealthStatus.resolve(skipCount: 1, evictAfterSkips: 3, isEvicted: false, isProtected: false) == .caution)
    }

    @Test("at risk skip count is critical")
    func atRiskIsCritical() {
        #expect(TrackHealthStatus.resolve(skipCount: 2, evictAfterSkips: 3, isEvicted: false, isProtected: false) == .critical)
        #expect(TrackHealthStatus.resolve(skipCount: 3, evictAfterSkips: 3, isEvicted: false, isProtected: false) == .critical)
    }

    @Test("threshold two only has healthy and critical")
    func thresholdTwoSkips() {
        #expect(TrackHealthStatus.resolve(skipCount: 0, evictAfterSkips: 2, isEvicted: false, isProtected: false) == .healthy)
        #expect(TrackHealthStatus.resolve(skipCount: 1, evictAfterSkips: 2, isEvicted: false, isProtected: false) == .critical)
    }

    @Test("threshold one only has healthy before eviction")
    func thresholdOneSkip() {
        #expect(TrackHealthStatus.resolve(skipCount: 0, evictAfterSkips: 1, isEvicted: false, isProtected: false) == .healthy)
        #expect(TrackHealthStatus.resolve(skipCount: 1, evictAfterSkips: 1, isEvicted: false, isProtected: false) == .critical)
    }
}
