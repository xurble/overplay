import Foundation
import Testing
@testable import Overplay

struct DomainVocabularyPayload<Value: Codable & Equatable>: Codable, Equatable {
    var value: Value
}

@Suite("Domain vocabulary")
struct DomainVocabularyTests {
    @Test("playlist source raw values are stable")
    func playlistSourceRawValuesAreStable() {
        #expect(PlaylistSource.appleMusic.rawValue == "appleMusic")
    }

    @Test("playlist role raw values are stable")
    func playlistRoleRawValuesAreStable() {
        #expect(PlaylistRole.oneTruePlaylist.rawValue == "oneTruePlaylist")
        #expect(PlaylistRole.triage.rawValue == "triage")
    }

    @Test("playlist write policy raw values are stable")
    func playlistWritePolicyRawValuesAreStable() {
        #expect(PlaylistWritePolicy.managed.rawValue == "managed")
        #expect(PlaylistWritePolicy.incomingOnly.rawValue == "incomingOnly")
    }

    @Test("history event type raw values are stable")
    func historyEventTypeRawValuesAreStable() {
        #expect(HistoryEventType.skipIgnored.rawValue == "skipIgnored")
        #expect(HistoryEventType.skipCounted.rawValue == "skipCounted")
        #expect(HistoryEventType.playthrough.rawValue == "playthrough")
        #expect(HistoryEventType.evicted.rawValue == "evicted")
        #expect(HistoryEventType.restored.rawValue == "restored")
        #expect(HistoryEventType.promoted.rawValue == "promoted")
        #expect(HistoryEventType.remoteMutation.rawValue == "remoteMutation")
    }

    @Test("event source raw values are stable")
    func eventSourceRawValuesAreStable() {
        #expect(HistoryEventSource.user.rawValue == "user")
        #expect(HistoryEventSource.playback.rawValue == "playback")
        #expect(HistoryEventSource.sync.rawValue == "sync")
        #expect(HistoryEventSource.appleMusic.rawValue == "appleMusic")
        #expect(HistoryEventSource.overplay.rawValue == "overplay")
    }

    @Test("eviction raw values are stable")
    func evictionRawValuesAreStable() {
        #expect(EvictionReason.skipCount.rawValue == "skipCount")
        #expect(EvictionReason.manual.rawValue == "manual")
        #expect(EvictionReason.remoteRemoval.rawValue == "remoteRemoval")
        #expect(EvictionSource.user.rawValue == "user")
        #expect(EvictionSource.playbackRule.rawValue == "playbackRule")
        #expect(EvictionSource.appleMusicSync.rawValue == "appleMusicSync")
    }

    @Test("remote mutation status raw values are stable")
    func remoteMutationStatusRawValuesAreStable() {
        #expect(RemoteMutationStatus.notAttempted.rawValue == "notAttempted")
        #expect(RemoteMutationStatus.pending.rawValue == "pending")
        #expect(RemoteMutationStatus.succeeded.rawValue == "succeeded")
        #expect(RemoteMutationStatus.failed.rawValue == "failed")
        #expect(RemoteMutationStatus.unsupported.rawValue == "unsupported")
    }

    @Test("domain vocabulary codable values round trip")
    func domainVocabularyCodableValuesRoundTrip() throws {
        try assertRoundTrips(PlaylistSource.appleMusic)
        try assertRoundTrips(PlaylistRole.oneTruePlaylist)
        try assertRoundTrips(PlaylistWritePolicy.incomingOnly)
        try assertRoundTrips(HistoryEventType.promoted)
        try assertRoundTrips(HistoryEventSource.sync)
        try assertRoundTrips(EvictionReason.skipCount)
        try assertRoundTrips(EvictionSource.appleMusicSync)
        try assertRoundTrips(RemoteMutationStatus.failed)
    }

    private func assertRoundTrips<Value: Codable & Equatable>(
        _ value: Value,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let payload = DomainVocabularyPayload(value: value)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DomainVocabularyPayload<Value>.self, from: data)
        #expect(decoded == payload, sourceLocation: sourceLocation)
    }
}
