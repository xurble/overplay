import Testing
@testable import Overplay

@MainActor
@Suite("Remote playlist mutation serialization")
struct PlaylistRemoteMutationCoordinatorTests {
    @MainActor
    private final class Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func pause() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test("Two retirements read sequential snapshots and preserve an intervening add")
    func overlappingWrites() async throws {
        let coordinator = PlaylistRemoteMutationCoordinator()
        let gate = Gate()
        var remote = ["A", "B", "C"]
        let first = Task {
            try await coordinator.rewrite(playlistID: "otp", isCurrent: { true }, load: {
                let snapshot = remote
                await gate.pause()
                return snapshot
            }, write: { remote = $0.filter { $0 != "A" } })
        }
        while !gate.entered { await Task.yield() }
        let second = Task {
            try await coordinator.rewrite(playlistID: "otp", isCurrent: { true }, load: { remote },
                                          write: { remote = $0.filter { $0 != "B" } })
        }
        let addition = Task {
            try await coordinator.perform(playlistID: "otp") { remote.append("D") }
        }
        gate.release()
        _ = try await first.value
        _ = try await second.value
        try await addition.value
        #expect(remote == ["C", "D"])
    }

    @Test("Retirement intent is checked again after the remote read")
    func supersededRetirement() async throws {
        let coordinator = PlaylistRemoteMutationCoordinator()
        let gate = Gate()
        var retired = true
        var remote = ["A", "B"]
        let removal = Task {
            try await coordinator.rewrite(playlistID: "otp", isCurrent: { retired }, load: {
                let snapshot = remote
                await gate.pause()
                return snapshot
            }, write: { remote = $0.filter { $0 != "A" } })
        }
        while !gate.entered { await Task.yield() }
        retired = false
        gate.release()
        #expect(try await removal.value == false)
        #expect(remote == ["A", "B"])
    }

    @Test("A queued re-promotion runs after retirement replacement")
    func sameTrackPromotion() async throws {
        let coordinator = PlaylistRemoteMutationCoordinator()
        let gate = Gate()
        var remote = ["A", "B"]
        let removal = Task {
            try await coordinator.rewrite(playlistID: "otp", isCurrent: { true }, load: {
                let snapshot = remote
                await gate.pause()
                return snapshot
            }, write: { remote = $0.filter { $0 != "A" } })
        }
        while !gate.entered { await Task.yield() }
        let promotion = Task {
            try await coordinator.perform(playlistID: "otp") { remote.append("A") }
        }
        gate.release()
        _ = try await removal.value
        try await promotion.value
        #expect(remote == ["B", "A"])
    }

    @Test("Failed requests release their gate and other playlists remain independent")
    func failureAndIndependentPlaylists() async throws {
        enum Failure: Error { case expected }
        let coordinator = PlaylistRemoteMutationCoordinator()
        let gate = Gate()
        let failure = Task {
            try await coordinator.perform(playlistID: "otp") {
                await gate.pause()
                throw Failure.expected
            }
        }
        while !gate.entered { await Task.yield() }
        let other = try await coordinator.perform(playlistID: "other") { 42 }
        #expect(other == 42)
        let queued = Task { try await coordinator.perform(playlistID: "otp") { 7 } }
        gate.release()
        do { try await failure.value; Issue.record("Expected failure") } catch Failure.expected { }
        #expect(try await queued.value == 7)
    }
}
