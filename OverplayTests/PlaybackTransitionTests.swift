import Foundation
import enum MediaPlayer.MPRemoteCommandHandlerStatus
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Player-confirmed playback transitions", .serialized)
struct PlaybackTransitionTests {
    @Test("Unlink preserves a playing session and prunes queued unowned songs without resetting modes")
    func unlinkDuringPlaybackPreservesAccounting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        let source = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source", name: "Source", trackCount: nil), in: fixture.context
        )
        for item in fixture.items {
            item.playlistID = bucket.id
            item.sourceMusicPlaylistIDs = ["source"]
        }
        fixture.items[2].isExplicitlyKept = true
        try fixture.context.save()
        await fixture.controller.playPlaylist(bucket, startingAt: fixture.tracks[0], settings: fixture.settings, context: fixture.context)
        fixture.player.playbackTime = 20
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.shuffleMode = .songs
        fixture.player.repeatMode = .all
        let queuedID = fixture.items[1].id
        let replacements = fixture.player.replaceQueueCallCount
        try fixture.controller.removeTriageSource(source, context: fixture.context)
        #expect(fixture.items[0].pendingRetentionCleanup)
        #expect(try PlaylistItemRepository.item(id: queuedID, in: fixture.context) == nil)
        #expect(fixture.player.queuedEntryCount == 2)
        #expect(fixture.player.replaceQueueCallCount == replacements)
        #expect(fixture.player.shuffleMode == .songs && fixture.player.repeatMode == .all)
        await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        #expect(fixture.items[0].skipCount == 1)
        #expect(!fixture.items[0].pendingRetentionCleanup)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[2].id.rawValue)
    }

    @Test("Retiring an untouched current Triage song deletes it without inventing a skip")
    func retireUntouchedCurrentSong() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        for item in fixture.items { item.playlistID = bucket.id; item.isExplicitlyKept = true }
        try fixture.context.save()
        await fixture.controller.playPlaylist(bucket, startingAt: fixture.tracks[0], settings: fixture.settings, context: fixture.context)
        let itemID = fixture.items[0].id
        await fixture.controller.evictCurrent(settings: fixture.settings, context: fixture.context)
        #expect(try PlaylistItemRepository.item(id: itemID, in: fixture.context) == nil)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(try fixture.history().filter { $0.eventType == .skipCounted }.isEmpty)
    }

    @Test("Moving a playing retired row to Triage preserves its unfinished playthrough")
    func rowMovementPreservesOngoingPlaythrough() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        for item in fixture.items {
            item.playlistID = bucket.id
            item.evictedAt = .now
            item.skipCount = 1
        }
        try fixture.context.save()
        await fixture.controller.playPlaylist(bucket, startingAt: fixture.tracks[0], scope: .retired, settings: fixture.settings, context: fixture.context)
        fixture.player.playbackTime = 20
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        try fixture.controller.restoreTrack(fixture.items[0], playlist: bucket, context: fixture.context)
        #expect(fixture.items[0].playthroughCount == 0)
        fixture.player.playbackTime = 179
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        #expect(fixture.items[0].playthroughCount == 1)
        #expect(fixture.items[0].evictedAt == nil && fixture.items[0].isExplicitlyKept)
    }

    @Test("confirmation policy never advances an unchanged or missing entry")
    func confirmationPolicyNeverAdvancesAnUnchangedOrMissingEntry() {
        let policy = PlaybackTransitionConfirmationPolicy(
            maximumObservationCount: 3,
            observationInterval: .zero
        )

        #expect(policy.resolution(
            outgoingEntryID: "outgoing",
            expectedEntryIDs: nil,
            observedEntryID: "outgoing"
        ) == .waiting)
        #expect(policy.resolution(
            outgoingEntryID: "outgoing",
            expectedEntryIDs: nil,
            observedEntryID: nil
        ) == .waiting)
        #expect(policy.resolution(
            outgoingEntryID: "outgoing",
            expectedEntryIDs: nil,
            observedEntryID: "incoming"
        ) == .confirmed(entryID: "incoming"))
        #expect(policy.resolution(
            outgoingEntryID: "outgoing",
            expectedEntryIDs: ["expected"],
            observedEntryID: "external"
        ) == .diverged(entryID: "external"))
    }

    @Test("a mode changed by another surface reaches Overplay")
    func modeChangedByAnotherSurfaceReachesOverplay() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        #expect(!fixture.controller.shuffleEnabled)

        // The Lock Screen, Siri or the Music app writing the mode directly.
        // `MusicPlayer.State` is not observable, so without noticing the
        // change Overplay would keep reporting the stale value forever.
        let versionBefore = fixture.controller.playbackModeVersion
        fixture.player.shuffleMode = .songs
        fixture.player.repeatMode = .all
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.shuffleEnabled)
        #expect(fixture.controller.repeatMode == .all)
        // The getters read the player directly, so their values are fresh
        // regardless. What an external change has to do is invalidate the
        // observation, or no surface redraws.
        #expect(fixture.controller.playbackModeVersion > versionBefore)

        let versionAfterNotice = fixture.controller.playbackModeVersion
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        #expect(fixture.controller.playbackModeVersion == versionAfterNotice)

        fixture.player.reportedShuffleMode = nil
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(!fixture.controller.shuffleEnabled)
        #expect(fixture.controller.playbackModeDiagnosticDescription.contains("rawShuffle=nil"))
        let nilTransition = try #require(
            MusicKitActivityLog.shared.snapshot().events.last {
                $0.operation == .playerModeObserved
                    && $0.detail?.contains("rawShuffle=songs->nil") == true
            }
        )
        #expect(nilTransition.detail?.contains("effectiveShuffle=songs->off") == true)
    }

    @Test("an active interruption never becomes a delivery stall or issues playback commands")
    func activeInterruptionNeverBecomesAStallOrIssuesPlaybackCommands() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let prepareCallsBeforeInterruption = fixture.player.prepareToPlayCallCount
        let playCallsBeforeInterruption = fixture.player.playCallCount

        fixture.player.playbackStatus = .interrupted
        for _ in 0..<20 {
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }

        #expect(fixture.player.prepareToPlayCallCount == prepareCallsBeforeInterruption)
        #expect(fixture.player.playCallCount == playCallsBeforeInterruption)
        #expect(!fixture.controller.isPlaying)
        #expect(!fixture.controller.isDeliveryStalled)
        #expect(fixture.controller.statusMessage == nil)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(fixture.items[0].playthroughCount == 0)
        #expect(try fixture.history().isEmpty)
    }

    @Test("an interruption beginning during recovery preparation prevents play")
    func interruptionDuringRecoveryPreparationPreventsPlay() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.controller.isNetworkReachable = { true }
        fixture.player.playbackTime = 10
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let prepareCallsBeforeStall = fixture.player.prepareToPlayCallCount
        let playCallsBeforeStall = fixture.player.playCallCount
        fixture.player.onPrepareToPlay = {
            fixture.player.playbackStatus = .interrupted
            await fixture.controller.reconcilePlayerState(context: fixture.context)
            fixture.player.playbackStatus = .playing
        }

        for _ in 0..<PlaybackDeliveryStallPolicy.frozenPlaybackTickThreshold {
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }

        #expect(fixture.player.prepareToPlayCallCount == prepareCallsBeforeStall + 1)
        #expect(fixture.player.playCallCount == playCallsBeforeStall)
        #expect(fixture.player.playbackStatus == .playing)
        #expect(!fixture.controller.isDeliveryStalled)
        #expect(fixture.items[0].skipCount == 0)
        #expect(fixture.items[0].playthroughCount == 0)
        #expect(try fixture.history().isEmpty)

        await fixture.controller.reconcilePlayerState(context: fixture.context)
        #expect(fixture.controller.isPlaying)
        #expect(fixture.player.playCallCount == playCallsBeforeStall)
    }

    @Test("post-interruption state follows MusicKit until an explicit play command")
    func postInterruptionStateFollowsMusicKitUntilExplicitPlay() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)

        fixture.player.playbackStatus = .interrupted
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let playCallsDuringInterruption = fixture.player.playCallCount

        fixture.player.playbackStatus = .playing
        fixture.player.playbackTime = 1
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.isPlaying)
        #expect(fixture.player.playCallCount == playCallsDuringInterruption)

        fixture.player.playbackStatus = .interrupted
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.playbackStatus = .paused
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(!fixture.controller.isPlaying)
        #expect(fixture.player.playCallCount == playCallsDuringInterruption)

        await fixture.controller.play(context: fixture.context)

        #expect(fixture.controller.isPlaying)
        #expect(fixture.player.playCallCount == playCallsDuringInterruption + 1)
        #expect(fixture.items[0].skipCount == 0)
        #expect(fixture.items[0].playthroughCount == 0)
        #expect(try fixture.history().isEmpty)
    }

    @Test("frozen playing delivery still uses the bounded recovery budget")
    func frozenPlayingDeliveryStillUsesBoundedRecovery() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.controller.isNetworkReachable = { true }
        fixture.player.playbackTime = 10
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let prepareCallsBeforeStall = fixture.player.prepareToPlayCallCount
        let playCallsBeforeStall = fixture.player.playCallCount

        for _ in 0..<30 {
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }

        #expect(fixture.controller.isDeliveryStalled)
        #expect(
            fixture.player.prepareToPlayCallCount
                == prepareCallsBeforeStall + PlaybackDeliveryStallPolicy.maximumRecoveryAttempts
        )
        #expect(
            fixture.player.playCallCount
                == playCallsBeforeStall + PlaybackDeliveryStallPolicy.maximumRecoveryAttempts
        )
    }

    @Test("a queue end is handled once, not once per tick")
    func queueEndIsHandledOncePerEnd() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 2)
        fixture.player.playbackTime = 179
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        let recordedBefore = MusicKitActivityLog.shared.snapshot().events
            .filter { $0.operation == .queueEndObserved }
            .count

        fixture.player.finishQueueNaturally()
        // `queueDidEnd` is a state, so every one of these ticks sees it. The
        // playthrough count alone cannot prove the guard works — that is
        // protected separately by `session.hasEvaluated` — so assert the
        // recording the guard actually governs.
        for _ in 0..<5 {
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }

        let recordedAfter = MusicKitActivityLog.shared.snapshot().events
            .filter { $0.operation == .queueEndObserved }
            .count
        #expect(recordedAfter - recordedBefore == 1)
        #expect(fixture.items[2].playthroughCount == 1)
        #expect(!fixture.controller.isDeliveryStalled)
        #expect(fixture.controller.statusMessage == nil)
    }

    @Test("an appended entry awaiting hydration never tears playback down")
    func appendedEntryAwaitingHydrationNeverTearsPlaybackDown() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let added = try fixture.addPlaylist(prefix: "appended", trackCount: 1)
        fixture.context.insert(PlaylistItemRecord(
            playlistID: fixture.playlist.id,
            trackID: added.tracks[0].id,
            createdAt: .now
        ))
        try fixture.context.save()

        // Sync adds a track to the playing playlist, and the player reports
        // that entry as current before its item hydrates.
        fixture.player.withholdsQueueItemIDs = true
        await fixture.controller.appendLiveQueueEntries(
            localTrackIDs: [added.tracks[0].id.uuidString],
            playlistID: fixture.playlist.musicPlaylistID,
            context: fixture.context
        )
        fixture.player.withholdsCurrentEntryItem = true
        for _ in fixture.musicTracks {
            fixture.player.advanceExternally()
        }
        for _ in 0..<8 {
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.canControlPlayback)

        fixture.player.withholdsQueueItemIDs = false
        fixture.player.withholdsCurrentEntryItem = false
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == added.musicTracks[0].id.rawValue)
        #expect(fixture.controller.canControlPlayback)
    }

    @Test("a queue replacement during append cannot mask a later external takeover")
    func queueReplacementDuringAppendCannotMaskExternalTakeover() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let other = try fixture.addPlaylist(prefix: "other", trackCount: 3)

        fixture.player.withholdsQueueItemIDs = true
        fixture.player.onAppendToQueue = {
            await fixture.controller.playPlaylist(
                other.playlist,
                settings: fixture.settings,
                context: fixture.context
            )
        }
        await fixture.controller.appendLiveQueueEntries(
            localTrackIDs: [fixture.tracks[2].id.uuidString],
            playlistID: fixture.playlist.musicPlaylistID,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == other.playlist.musicPlaylistID)

        // The new external queue happens to contain the song from the stale
        // append. Its entry must not be adopted as part of the replacement
        // playlist merely because the song IDs match.
        fixture.player.withholdsQueueItemIDs = false
        fixture.player.replaceQueueExternally(with: [fixture.musicTracks[2]])
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.currentPlaylistID == nil)
        #expect(fixture.controller.activePlaylistSnapshot == nil)
    }

    @Test("syncing a source refreshes and extends the playing triage bucket")
    func syncingSourceRefreshesAndExtendsPlayingTriageBucket() async throws {
        let fixture = try makeFixture(trackCount: 2)
        fixture.playlist.musicPlaylistID = PlaylistRecord.triageBucketMusicPlaylistID
        fixture.playlist.name = PlaylistRecord.triageBucketName
        fixture.playlist.role = .triageBucket
        fixture.playlist.writePolicy = .incomingOnly
        defer { fixture.cleanUp() }
        try fixture.context.save()
        try await fixture.start(at: 0)

        let source = try fixture.addPlaylist(prefix: "source", trackCount: 1)
        let contributedItem = source.items[0]
        contributedItem.playlistID = fixture.playlist.id
        contributedItem.addSourceMusicPlaylistID(source.playlist.musicPlaylistID)
        try fixture.context.save()

        // Source sync already updated the durable order before notifying the
        // controller. The controller must still compare against the live queue
        // and publish the newly persisted bucket row.
        let contributedLocalTrackID = source.tracks[0].id.uuidString
        let storedOrder = PlaybackOrderStore.state(
            playerID: fixture.playerID,
            musicPlaylistID: fixture.playlist.musicPlaylistID
        ).orderedTrackIDs + [contributedLocalTrackID]
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: fixture.playerID,
                musicPlaylistID: fixture.playlist.musicPlaylistID,
                orderedTrackIDs: storedOrder
            ),
            flushImmediately: true
        )

        fixture.controller.reconcileStoredOrder(for: source.playlist, context: fixture.context)
        fixture.controller.reconcileStoredOrder(for: source.playlist, context: fixture.context)
        await Task.yield()

        #expect(fixture.player.appendedTrackBatchSizes == [1])
        #expect(fixture.player.queuedEntryCount == 3)
        #expect(fixture.controller.activePlaylistSnapshot?.musicPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.contains {
            $0.localTrackID == contributedLocalTrackID
                && $0.sourceMusicPlaylistIDs == [source.playlist.musicPlaylistID]
        } == true)
    }

    @Test("a bucket alias callback reconciles the canonical playing bucket")
    func bucketAliasCallbackReconcilesCanonicalPlayingBucket() async throws {
        let fixture = try makeFixture(trackCount: 2)
        fixture.playlist.musicPlaylistID = PlaylistRecord.triageBucketMusicPlaylistID
        fixture.playlist.name = PlaylistRecord.triageBucketName
        fixture.playlist.role = .triageBucket
        fixture.playlist.writePolicy = .incomingOnly
        fixture.playlist.createdAt = Date(timeIntervalSince1970: 200)
        defer { fixture.cleanUp() }
        try fixture.context.save()
        try await fixture.start(at: 0)

        let imported = try fixture.addPlaylist(prefix: "imported-bucket", trackCount: 1)
        imported.playlist.musicPlaylistID = PlaylistRecord.triageBucketMusicPlaylistID
        imported.playlist.name = PlaylistRecord.triageBucketName
        imported.playlist.role = .triageBucket
        imported.playlist.writePolicy = .incomingOnly
        imported.playlist.createdAt = Date(timeIntervalSince1970: 100)
        try fixture.context.save()

        // A refresh can discover that the view's bucket record is now an
        // inactive alias because an older CloudKit bucket became canonical.
        let canonicalBucket = try PlaylistRepository.triageBucket(in: fixture.context)
        #expect(canonicalBucket.id == imported.playlist.id)
        #expect(fixture.playlist.isActive == false)
        try fixture.context.save()

        fixture.controller.reconcileStoredOrder(for: fixture.playlist, context: fixture.context)
        await Task.yield()

        let importedLocalTrackID = imported.tracks[0].id.uuidString
        #expect(fixture.player.appendedTrackBatchSizes == [1])
        #expect(fixture.player.queuedEntryCount == 3)
        #expect(fixture.controller.activePlaylistSnapshot?.playlistID == canonicalBucket.id)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.contains {
            $0.localTrackID == importedLocalTrackID
        } == true)
    }

    @Test("a promoted source sync callback still refreshes the playing triage bucket")
    func promotedSourceSyncCallbackStillRefreshesPlayingTriageBucket() async throws {
        let fixture = try makeFixture(trackCount: 2)
        fixture.playlist.musicPlaylistID = PlaylistRecord.triageBucketMusicPlaylistID
        fixture.playlist.name = PlaylistRecord.triageBucketName
        fixture.playlist.role = .triageBucket
        fixture.playlist.writePolicy = .incomingOnly
        defer { fixture.cleanUp() }
        try fixture.context.save()
        try await fixture.start(at: 0)

        let source = try fixture.addPlaylist(prefix: "source", trackCount: 1)
        let contributedItem = source.items[0]
        contributedItem.playlistID = fixture.playlist.id
        contributedItem.addSourceMusicPlaylistID(source.playlist.musicPlaylistID)
        source.playlist.role = .oneTruePlaylist
        try fixture.context.save()

        let contributedLocalTrackID = source.tracks[0].id.uuidString
        let storedOrder = PlaybackOrderStore.state(
            playerID: fixture.playerID,
            musicPlaylistID: fixture.playlist.musicPlaylistID
        ).orderedTrackIDs + [contributedLocalTrackID]
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: fixture.playerID,
                musicPlaylistID: fixture.playlist.musicPlaylistID,
                orderedTrackIDs: storedOrder
            ),
            flushImmediately: true
        )

        fixture.controller.reconcileStoredOrder(for: source.playlist, context: fixture.context)
        await Task.yield()

        #expect(fixture.player.appendedTrackBatchSizes == [1])
        #expect(fixture.player.queuedEntryCount == 3)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.contains {
            $0.localTrackID == contributedLocalTrackID
        } == true)
    }

    @Test("syncing a source after partial queue hydration appends only its new track")
    func syncingSourceAfterPartialQueueHydrationAppendsOnlyItsNewTrack() async throws {
        let fixture = try makeFixture(trackCount: 2)
        fixture.playlist.musicPlaylistID = PlaylistRecord.triageBucketMusicPlaylistID
        fixture.playlist.name = PlaylistRecord.triageBucketName
        fixture.playlist.role = .triageBucket
        fixture.playlist.writePolicy = .incomingOnly
        defer { fixture.cleanUp() }
        try fixture.context.save()
        try await fixture.start(at: 0)

        // MusicKit can re-materialize the queue under fresh entry IDs and
        // hydrate only part of it. The second original track is still live,
        // even though it is temporarily absent from the controller's mapped
        // queue.
        let reissued = fixture.player.reissueEntryIDs(for: fixture.musicTracks, currentIndex: 0)
        fixture.player.unhydratedEntryIDs = [reissued[1]]
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        // Hydration finishes before the source-sync callback, but there is no
        // intervening playback tick to merge that entry into the controller's
        // mapped queue.
        fixture.player.unhydratedEntryIDs = []

        let source = try fixture.addPlaylist(prefix: "source", trackCount: 1)
        let contributedItem = source.items[0]
        contributedItem.playlistID = fixture.playlist.id
        contributedItem.addSourceMusicPlaylistID(source.playlist.musicPlaylistID)
        try fixture.context.save()

        let contributedLocalTrackID = source.tracks[0].id.uuidString
        let storedOrder = PlaybackOrderStore.state(
            playerID: fixture.playerID,
            musicPlaylistID: fixture.playlist.musicPlaylistID
        ).orderedTrackIDs + [contributedLocalTrackID]
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: fixture.playerID,
                musicPlaylistID: fixture.playlist.musicPlaylistID,
                orderedTrackIDs: storedOrder
            ),
            flushImmediately: true
        )

        fixture.controller.reconcileStoredOrder(for: source.playlist, context: fixture.context)
        fixture.controller.reconcileStoredOrder(for: source.playlist, context: fixture.context)
        await Task.yield()

        #expect(fixture.player.appendedTrackBatchSizes == [1])
        #expect(fixture.player.queuedEntryCount == 3)

        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.player.appendedTrackBatchSizes == [1])
        #expect(fixture.player.queuedEntryCount == 3)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.contains {
            $0.localTrackID == contributedLocalTrackID
        } == true)
    }

    @Test("demoting the playing main playlist keeps its queue attached to the bucket")
    func demotingPlayingMainPlaylistKeepsItsQueueAttachedToBucket() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        let bucketTrack = TrackRecord(title: "Bucket", artistName: "Artist")
        fixture.context.insert(bucketTrack)
        fixture.context.insert(PlaylistItemRecord(playlistID: bucket.id, trackID: bucketTrack.id))
        let activeBucketOnlyTrackID = bucketTrack.id.uuidString
        let retiredBucketTrackID = "bucket-retired"
        let retiredSourceTrackID = "source-retired"
        defer {
            for scope in PlaylistPlaybackScope.allCases {
                PlaybackOrderStore.clear(
                    playerID: fixture.playerID,
                    musicPlaylistID: scope.playbackOrderPlaylistID(for: fixture.playlist.musicPlaylistID),
                    flushImmediately: true
                )
                PlaybackOrderStore.clear(
                    playerID: fixture.playerID,
                    musicPlaylistID: scope.playbackOrderPlaylistID(for: bucket.musicPlaylistID),
                    flushImmediately: true
                )
            }
            PlaybackIdentityStore.clear(
                playerID: fixture.playerID,
                musicPlaylistID: fixture.playlist.musicPlaylistID,
                flushImmediately: true
            )
            PlaybackIdentityStore.clear(
                playerID: fixture.playerID,
                musicPlaylistID: bucket.musicPlaylistID,
                flushImmediately: true
            )
        }
        PlaybackOrderStore.save(PlaybackOrderState(
            playerID: fixture.playerID,
            musicPlaylistID: bucket.musicPlaylistID,
            orderedTrackIDs: [activeBucketOnlyTrackID]
        ))
        PlaybackOrderStore.save(PlaybackOrderState(
            playerID: fixture.playerID,
            musicPlaylistID: PlaylistPlaybackScope.retired.playbackOrderPlaylistID(
                for: fixture.playlist.musicPlaylistID
            ),
            orderedTrackIDs: [retiredSourceTrackID]
        ))
        PlaybackOrderStore.save(PlaybackOrderState(
            playerID: fixture.playerID,
            musicPlaylistID: PlaylistPlaybackScope.retired.playbackOrderPlaylistID(
                for: bucket.musicPlaylistID
            ),
            orderedTrackIDs: [retiredBucketTrackID]
        ))
        let currentLocalTrackID = fixture.tracks[0].id.uuidString
        PlaybackIdentityStore.recordAlias(
            "source-alias",
            playerID: fixture.playerID,
            musicPlaylistID: fixture.playlist.musicPlaylistID,
            localTrackID: currentLocalTrackID
        )
        PlaybackIdentityStore.recordAlias(
            "bucket-alias",
            playerID: fixture.playerID,
            musicPlaylistID: bucket.musicPlaylistID,
            localTrackID: currentLocalTrackID
        )

        try SettingsRepository.selectPlaylist(
            AppleMusicPlaylist(id: "replacement", name: "Replacement", trackCount: 0),
            in: fixture.context
        )
        fixture.controller.reconcilePlaylistSelection(context: fixture.context)

        #expect(fixture.controller.currentPlaylistID == bucket.musicPlaylistID)
        #expect(fixture.controller.currentPlaylistItem?.playlistID == bucket.id)
        #expect(fixture.controller.activePlaylistSnapshot?.playlistID == bucket.id)
        let liveQueueOrder = fixture.tracks.map { $0.id.uuidString }
        let mergedActiveOrder = PlaybackOrderStore.state(
            playerID: fixture.playerID,
            musicPlaylistID: bucket.musicPlaylistID
        ).orderedTrackIDs
        #expect(Array(mergedActiveOrder.prefix(liveQueueOrder.count)) == liveQueueOrder)
        #expect(mergedActiveOrder.contains(activeBucketOnlyTrackID))
        #expect(PlaybackOrderStore.state(
            playerID: fixture.playerID,
            musicPlaylistID: PlaylistPlaybackScope.retired.playbackOrderPlaylistID(
                for: bucket.musicPlaylistID
            )
        ).orderedTrackIDs == [retiredBucketTrackID, retiredSourceTrackID])
        #expect(Set(PlaybackIdentityStore.aliases(
            playerID: fixture.playerID,
            musicPlaylistID: bucket.musicPlaylistID,
            localTrackID: currentLocalTrackID
        )) == ["source-alias", "bucket-alias"])
        #expect(PlaybackIdentityStore.aliases(
            playerID: fixture.playerID,
            musicPlaylistID: fixture.playlist.musicPlaylistID,
            localTrackID: currentLocalTrackID
        ).isEmpty)

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        let movedItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: fixture.context)
        let outgoingItem = try #require(movedItems.first { $0.trackID == fixture.tracks[0].id })
        #expect(outgoingItem.skipCount == 1)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
    }

    @Test("a queue replacement clears an earlier pending append correlation")
    func queueReplacementClearsEarlierPendingAppendCorrelation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let other = try fixture.addPlaylist(prefix: "other", trackCount: 3)

        fixture.player.withholdsQueueItemIDs = true
        await fixture.controller.appendLiveQueueEntries(
            localTrackIDs: [fixture.tracks[2].id.uuidString],
            playlistID: fixture.playlist.musicPlaylistID,
            context: fixture.context
        )
        await fixture.controller.playPlaylist(
            other.playlist,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == other.playlist.musicPlaylistID)

        fixture.player.withholdsQueueItemIDs = false
        fixture.player.replaceQueueExternally(with: [fixture.musicTracks[2]])
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.currentPlaylistID == nil)
        #expect(fixture.controller.activePlaylistSnapshot == nil)
    }

    @Test("delayed Next keeps every published surface on outgoing until confirmation")
    func delayedNextKeepsPublishedStateOnOutgoingUntilConfirmation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.nextConfirmationDelays = [2]
        fixture.sleepProbe.handler = {
            fixture.sleepProbe.observedTrackIDs.append(fixture.controller.currentTrack?.id)
            fixture.sleepProbe.observedRestoreTrackIDs.append(LocalPlaybackStateStore.load()?.musicItemID)
            fixture.sleepProbe.observedCurrentRowTrackIDs.append(
                fixture.controller.activePlaylistSnapshot?.rows.first(where: \.isCurrent)?.localTrackID
            )
        }

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.sleepProbe.observedTrackIDs == [fixture.musicTracks[0].id.rawValue, fixture.musicTracks[0].id.rawValue])
        #expect(fixture.sleepProbe.observedRestoreTrackIDs == [fixture.musicTracks[0].id.rawValue, fixture.musicTracks[0].id.rawValue])
        #expect(fixture.sleepProbe.observedCurrentRowTrackIDs == [fixture.tracks[0].id.uuidString, fixture.tracks[0].id.uuidString])
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[0].skipCount == 1)
        #expect(fixture.items[1].skipCount == 0)
        #expect(try fixture.history().count == 1)
    }

    @Test("an in-queue skip evaluates the outgoing track once and keeps the queue order")
    func inQueueSkipEvaluatesOutgoingOnceAndKeepsQueueOrder() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        let didSkip = await fixture.controller.playTrackInCurrentQueue(
            localTrackID: fixture.tracks[2].id.uuidString,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(didSkip)
        #expect(fixture.player.skipToEntryCallCount == 1)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[2].id.rawValue)
        // Only the outgoing track is evaluated; the one jumped over is not.
        #expect(fixture.items[0].skipCount == 1)
        #expect(fixture.items[1].skipCount == 0)
        #expect(fixture.items[2].skipCount == 0)
        #expect(try fixture.history().count == 1)
    }

    @Test("tapping the live track resumes it instead of restarting it")
    func tappingTheLiveTrackResumesInsteadOfRestarting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.controller.pause()

        let didSkip = await fixture.controller.playTrackInCurrentQueue(
            localTrackID: fixture.tracks[0].id.uuidString,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(didSkip)
        #expect(fixture.player.skipToEntryCallCount == 0)
        #expect(fixture.controller.isPlaying)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)
    }

    @Test("a track outside the live queue is left to the caller to start")
    func trackOutsideTheLiveQueueIsLeftToTheCaller() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let other = try fixture.addPlaylist(prefix: "other", trackCount: 2)

        let didSkip = await fixture.controller.playTrackInCurrentQueue(
            localTrackID: other.tracks[0].id.uuidString,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(!didSkip)
        #expect(fixture.player.skipToEntryCallCount == 0)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
    }

    @Test("an external queue replacement hands the track back to the caller")
    func externalQueueReplacementHandsTheTrackBackToTheCaller() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let other = try fixture.addPlaylist(prefix: "other", trackCount: 3)

        // Apple Music switches queues behind our back: the controller still
        // holds queue entries the player no longer has.
        let replacement = try PlaybackQueueOrchestrator.orderedCachedQueueEntries(
            for: other.playlist.musicPlaylistID,
            playerID: fixture.playerID,
            startingTrackID: nil,
            scope: .active,
            in: fixture.context
        )
        fixture.player.replaceQueue(
            with: PlaybackQueueMaterializer.materialize(replacement, startingAt: nil)
        )

        let didSkip = await fixture.controller.playTrackInCurrentQueue(
            localTrackID: fixture.tracks[2].id.uuidString,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(!didSkip)
        #expect(fixture.player.skipToEntryCallCount == 0)
        #expect(!fixture.controller.isDeliveryStalled)
    }

    @Test("a failed in-queue skip reports a stall and keeps the outgoing track")
    func failedInQueueSkipReportsStallAndKeepsOutgoingTrack() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.skipToEntryFailuresRemaining = 1

        let didSkip = await fixture.controller.playTrackInCurrentQueue(
            localTrackID: fixture.tracks[2].id.uuidString,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(didSkip)
        #expect(fixture.controller.isDeliveryStalled)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)
    }

    @Test("a timed-out in-queue skip commits no history and keeps the outgoing track")
    func timedOutInQueueSkipCommitsNoHistoryAndKeepsOutgoingTrack() async throws {
        let fixture = try makeFixture(maximumObservationCount: 2)
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.skipToEntryConfirmationDelays = [5]

        let didSkip = await fixture.controller.playTrackInCurrentQueue(
            localTrackID: fixture.tracks[2].id.uuidString,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(didSkip)
        #expect(fixture.controller.statusMessage == PlaybackTransitionError.confirmationTimedOut.localizedDescription)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)
    }

    @Test("failed and timed-out Next preserve identity and commit no history")
    func failedAndTimedOutNextPreserveIdentityAndCommitNoHistory() async throws {
        let failed = try makeFixture()
        defer { failed.cleanUp() }
        try await failed.start(at: 0)
        failed.player.playbackTime = 15
        await failed.controller.reconcilePlayerState(context: failed.context)
        failed.player.nextFailuresRemaining = 1

        await failed.controller.next(settings: failed.settings, context: failed.context)

        #expect(failed.controller.currentTrack?.id == failed.musicTracks[0].id.rawValue)
        #expect(failed.items[0].skipCount == 0)
        #expect(try failed.history().isEmpty)
        #expect(failed.controller.isDeliveryStalled)
        #expect(failed.controller.remoteCommandAvailability.canPlay)
        #expect(!failed.controller.remoteCommandAvailability.canPause)

        let timedOut = try makeFixture(maximumObservationCount: 3)
        defer { timedOut.cleanUp() }
        try await timedOut.start(at: 0)
        timedOut.player.playbackTime = 15
        await timedOut.controller.reconcilePlayerState(context: timedOut.context)
        timedOut.player.nextConfirmationDelays = [100]

        await timedOut.controller.next(settings: timedOut.settings, context: timedOut.context)

        #expect(timedOut.controller.currentTrack?.id == timedOut.musicTracks[0].id.rawValue)
        #expect(timedOut.items[0].skipCount == 0)
        #expect(try timedOut.history().isEmpty)
        #expect(timedOut.controller.statusMessage == PlaybackTransitionError.confirmationTimedOut.localizedDescription)
    }

    @Test("Next does not confirm when a temporarily missing outgoing entry reappears unchanged")
    func temporarilyMissingOutgoingEntryDoesNotConfirmUnchangedNext() async throws {
        let fixture = try makeFixture(maximumObservationCount: 3)
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.suppressCurrentEntryReporting = true
        fixture.player.nextRevealsUnchangedEntry = true

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.nextCallCount == 1)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)
        #expect(fixture.controller.statusMessage == PlaybackTransitionError.confirmationTimedOut.localizedDescription)
    }

    @Test("rapid Next rejects overlap and evaluates the outgoing track once")
    func rapidNextRejectsOverlapAndEvaluatesOutgoingOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.blockNextCommand = true

        let first = Task { @MainActor in
            await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        }
        while fixture.player.nextCallCount == 0 {
            await Task.yield()
        }
        #expect(fixture.controller.isPlaybackTransitionInFlight)
        #expect(fixture.controller.remoteCommandAvailability == .unavailable)
        let second = Task { @MainActor in
            await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        }
        await second.value
        fixture.player.releaseBlockedNextCommand()
        await first.value

        #expect(fixture.player.nextCallCount == 1)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[0].skipCount == 1)
        #expect(try fixture.history().count == 1)
    }

    @Test("remote Next reports failure before scheduling when settings cannot load")
    func remoteNextReportsSynchronousSettingsFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let service = RemoteCommandService()

        let status = service.handleNextCommand(
            playbackController: fixture.controller,
            context: fixture.context,
            settingsProvider: { _ in throw ReconciliationTestFailure.expected }
        )
        await Task.yield()

        #expect(status == .commandFailed)
        #expect(fixture.player.nextCallCount == 0)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
    }

    @Test("stable playback reconciliation preserves the active snapshot revision")
    func stablePlaybackReconciliationPreservesActiveSnapshotRevision() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let revision = try #require(fixture.controller.activePlaylistSnapshot?.updatedAt)

        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.activePlaylistSnapshot?.updatedAt == revision)
    }

    @Test("failed Previous does not poison a later countable transition")
    func failedPreviousDoesNotPoisonLaterTransition() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 1)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.previousFailuresRemaining = 1

        await fixture.controller.previous(context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[1].skipCount == 0)

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[2].id.rawValue)
        #expect(fixture.items[1].skipCount == 1)
        #expect(try fixture.history().count == 1)
    }

    @Test("playlist replacement failure restores prior correlation before a later success")
    func playlistReplacementFailureRestoresPriorCorrelationBeforeSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let target = try fixture.addPlaylist(prefix: "replacement", trackCount: 2)
        fixture.player.playFailuresRemaining = 1

        await fixture.controller.playPlaylist(
            target.playlist,
            startingAt: target.tracks[0],
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)

        await fixture.controller.playPlaylist(
            target.playlist,
            startingAt: target.tracks[0],
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == target.playlist.musicPlaylistID)
        #expect(fixture.controller.currentTrack?.id == target.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 1)
        #expect(try fixture.history().count == 1)
    }

    @Test("failed queue restoration clears stale playback identity")
    func failedQueueRestorationClearsStalePlaybackIdentity() async throws {
        let fixture = try makeFixture(maximumObservationCount: 3)
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let target = try fixture.addPlaylist(prefix: "unrestorable", trackCount: 2)
        fixture.player.playFailuresRemaining = 1
        fixture.player.replacementConfirmationDelays = [0, 100]
        fixture.player.clearCurrentEntryWhileReplacementPending = true

        await fixture.controller.playPlaylist(
            target.playlist,
            startingAt: target.tracks[0],
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == nil)
        #expect(fixture.controller.currentTrack == nil)
        #expect(fixture.controller.activePlaylistSnapshot == nil)
        #expect(LocalPlaybackStateStore.load() == nil)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)
    }

    @Test("shuffle is a mode change, not a reorder and restart")
    func shuffleIsAModeChangeNotAReorderAndRestart() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let replacementsBefore = fixture.player.replaceQueueCallCount

        await fixture.controller.setShuffleEnabled(true, context: fixture.context)

        // MusicKit shuffles the queue it already holds: nothing is reordered,
        // requeued or restarted, and the current track keeps playing — so no
        // skip is counted against it either.
        #expect(fixture.controller.shuffleEnabled)
        #expect(fixture.player.shuffleMode == .songs)
        #expect(NowPlayingPresentationFactory.playbackControlsPresentation(
            playbackController: fixture.controller
        ).isShuffling)
        #expect(fixture.player.replaceQueueCallCount == replacementsBefore)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)

        await fixture.controller.toggleShuffle(context: fixture.context)
        #expect(!fixture.controller.shuffleEnabled)
        #expect(fixture.player.shuffleMode == .off)
        #expect(!NowPlayingPresentationFactory.playbackControlsPresentation(
            playbackController: fixture.controller
        ).isShuffling)
    }

    @Test("repeat all toggles on and off without rebuilding the queue")
    func repeatAllTogglesWithoutRebuildingQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let replacementsBefore = fixture.player.replaceQueueCallCount

        await fixture.controller.toggleRepeatAll(context: fixture.context)
        #expect(fixture.player.repeatMode == .all)
        #expect(fixture.controller.repeatAllEnabled)
        #expect(NowPlayingPresentationFactory.playbackControlsPresentation(
            playbackController: fixture.controller
        ).isRepeatingAll)

        await fixture.controller.toggleRepeatAll(context: fixture.context)
        #expect(fixture.player.repeatMode == MusicPlayer.RepeatMode.none)
        #expect(!fixture.controller.repeatAllEnabled)
        #expect(!NowPlayingPresentationFactory.playbackControlsPresentation(
            playbackController: fixture.controller
        ).isRepeatingAll)

        fixture.player.repeatMode = .one
        await fixture.controller.toggleRepeatAll(context: fixture.context)
        #expect(fixture.player.repeatMode == .all)
        #expect(fixture.controller.repeatAllEnabled)

        #expect(fixture.player.replaceQueueCallCount == replacementsBefore)
    }

    @Test("the last track is credited at queue end, and Overplay does not restart")
    func lastTrackIsCreditedAtQueueEndWithoutRestarting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 2)
        fixture.player.playbackTime = 179
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let replacementsBefore = fixture.player.replaceQueueCallCount

        fixture.player.finishQueueNaturally()
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        // MusicKit owns repeat, so nothing plays next unless it says so — but
        // the track that just finished still has to be counted.
        #expect(fixture.items[2].playthroughCount == 1)
        #expect(fixture.items[2].skipCount == 0)
        #expect(fixture.player.replaceQueueCallCount == replacementsBefore)
    }

    @Test("externally observed natural advance uses the same reconciliation path")
    func externallyObservedNaturalAdvanceUsesSharedReconciliation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 179
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.advanceExternally()

        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[0].playthroughCount == 1)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().count == 1)
    }

    @Test("recovered current playthrough immediately republishes controller metadata")
    func recoveredCurrentPlaythroughRepublishesControllerMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let previousMetadataVersion = fixture.controller.playbackItemMetadataVersion
        fixture.player.playbackTime = 180
        let reconciliationContext = ModelContext(fixture.container)

        let result = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: fixture.controller,
            context: reconciliationContext,
            musicLibraryFetcher: EmptyMusicLibraryPlaybackHistoryFetcher()
        )
        let verificationContext = ModelContext(fixture.container)
        let persistedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[0].id,
            in: verificationContext
        ))

        #expect(result.countedLocalTrackIDs == [fixture.tracks[0].id.uuidString])
        #expect(persistedItem.playthroughCount == 1)
        #expect(fixture.controller.currentTrack?.playthroughCount == 1)
        #expect(fixture.controller.displayedPlaythroughCount == 1)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first {
            $0.localTrackID == fixture.tracks[0].id.uuidString
        }?.playthroughCount == 1)
        #expect(fixture.controller.playbackItemMetadataVersion > previousMetadataVersion)
        #expect(try verificationContext.fetch(FetchDescriptor<HistoryEvent>()).count == 1)
    }

    @Test("failed recovered playthrough save publishes nothing and remains retryable")
    func failedRecoveredPlaythroughSavePublishesNothingAndRemainsRetryable() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 180
        PlaybackWaypointStore.clear(flushImmediately: true)

        let failedResult = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: fixture.controller,
            context: ModelContext(fixture.container),
            musicLibraryFetcher: EmptyMusicLibraryPlaybackHistoryFetcher(),
            saveChanges: { _ in throw ReconciliationTestFailure.expected }
        )
        let failedVerificationContext = ModelContext(fixture.container)
        let unchangedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[0].id,
            in: failedVerificationContext
        ))

        #expect(failedResult.countedLocalTrackIDs.isEmpty)
        #expect(unchangedItem.playthroughCount == 0)
        #expect(try failedVerificationContext.fetch(FetchDescriptor<HistoryEvent>()).isEmpty)
        #expect(PlaybackWaypointStore.load() == nil)
        #expect(fixture.controller.currentTrack?.playthroughCount == 0)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first?.playthroughCount == 0)

        let retryResult = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: fixture.controller,
            context: ModelContext(fixture.container),
            musicLibraryFetcher: EmptyMusicLibraryPlaybackHistoryFetcher()
        )
        let retryVerificationContext = ModelContext(fixture.container)
        let persistedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[0].id,
            in: retryVerificationContext
        ))

        #expect(retryResult.countedLocalTrackIDs == [fixture.tracks[0].id.uuidString])
        #expect(persistedItem.playthroughCount == 1)
        #expect(try retryVerificationContext.fetch(FetchDescriptor<HistoryEvent>()).count == 1)
        #expect(fixture.controller.currentTrack?.playthroughCount == 1)
    }

    @Test("recovered non-current playthroughs patch the active projection after player reconciliation")
    func recoveredNonCurrentPlaythroughsPatchActiveProjection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 170
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        PlaybackWaypointStore.save(
            PlaybackWaypoint(
                playlistID: fixture.playlist.musicPlaylistID,
                localTrackID: fixture.tracks[0].id.uuidString,
                positionSeconds: 170,
                durationSeconds: 180,
                recordedAt: Date().addingTimeInterval(-200)
            ),
            flushImmediately: true
        )
        fixture.player.advanceExternally()
        fixture.player.advanceExternally()
        fixture.player.playbackTime = 10
        let reconciliationContext = ModelContext(fixture.container)

        let result = await PlaybackReconciliationService.reconcileAndCaptureWaypoint(
            playbackController: fixture.controller,
            context: reconciliationContext,
            musicLibraryFetcher: EmptyMusicLibraryPlaybackHistoryFetcher()
        )
        let verificationContext = ModelContext(fixture.container)
        let firstPersistedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[0].id,
            in: verificationContext
        ))
        let secondPersistedItem = try #require(try PlaylistItemRepository.item(
            id: fixture.items[1].id,
            in: verificationContext
        ))

        #expect(result.countedLocalTrackIDs == [
            fixture.tracks[0].id.uuidString,
            fixture.tracks[1].id.uuidString
        ])
        #expect(firstPersistedItem.playthroughCount == 1)
        #expect(secondPersistedItem.playthroughCount == 1)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[2].id.rawValue)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first {
            $0.localTrackID == fixture.tracks[0].id.uuidString
        }?.playthroughCount == 1)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first {
            $0.localTrackID == fixture.tracks[1].id.uuidString
        }?.playthroughCount == 1)
        #expect(fixture.controller.activePlaylistSnapshot?.rows.first {
            $0.localTrackID == fixture.tracks[2].id.uuidString
        }?.isCurrent == true)
        #expect(try verificationContext.fetch(FetchDescriptor<HistoryEvent>()).count == 2)
    }

    @Test("Next landing outside the realized queue clears stale playlist correlation")
    func nextOutsideQueueClearsStalePlaylistCorrelation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let external = try fixture.addPlaylist(prefix: "external", trackCount: 1)
        fixture.player.nextEntryOverride = MusicPlayer.Queue.Entry(external.musicTracks[0])

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == external.musicTracks[0].id.rawValue)
        #expect(fixture.controller.currentPlaylistID == nil)
        #expect(fixture.controller.nowPlayingDisplayLocalTrackID == nil)
        #expect(fixture.controller.activePlaylistSnapshot == nil)
        #expect(LocalPlaybackStateStore.load() == nil)
        #expect(fixture.items[0].skipCount == 1)
        #expect(try fixture.history().count == 1)
    }

    // MARK: - Correlation rebuilt from the live player queue

    @Test("a queue re-materialized under new entry IDs keeps its playlist, its controls and its counting")
    func requeuedUnderNewEntryIDsKeepsPlaylistControlsAndCounting() async throws {
        // MusicKit owns shuffle now, and a mode change reorders the queue it
        // holds — handing back entries whose IDs Overplay never minted.
        // Reading that as a diverged transition dropped the playlist, which
        // disabled Next/Previous and stopped every play and skip being
        // counted for a queue still playing exactly what Overplay asked for.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)

        await fixture.controller.setShuffleEnabled(true, context: fixture.context)
        fixture.player.reissueEntryIDs(for: fixture.musicTracks, currentIndex: 0)
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.shuffleEnabled)
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.controller.currentPlaylistItem?.trackID == fixture.tracks[0].id)
        #expect(fixture.controller.canControlPlayback)
        #expect(fixture.controller.canSkipTracks)
        #expect(LocalPlaybackStateStore.load()?.playlistID == fixture.playlist.musicPlaylistID)

        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.items[0].skipCount == 1)
        #expect(try fixture.history().contains { $0.eventType == .skipCounted })
    }

    @Test("a queue re-materialized during initial playback still records a five-second skip")
    func requeuedDuringInitialPlaybackStillRecordsSkip() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.settings.minimumSkipListeningSeconds = 5
        fixture.player.reissuedTracksOnReplace = fixture.musicTracks

        try await fixture.start(at: 0)
        for second in 1...6 {
            fixture.player.playbackTime = Double(second)
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }

        await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        await fixture.controller.previous(context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.items[0].skipCount == 1)
        #expect(fixture.controller.displayedSkipCount(context: fixture.context) == 1)
        #expect(fixture.controller.displayedPlaythroughCount(context: fixture.context) == 0)
        #expect(try fixture.history().filter { $0.eventType == .skipCounted }.count == 1)
    }

    @Test("a foreign queue during initial playback is not adopted as the requested playlist")
    func foreignQueueDuringInitialPlaybackRemainsDivergence() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let external = try fixture.addPlaylist(prefix: "external", trackCount: 1)
        fixture.player.reissuedTracksOnReplace = external.musicTracks

        await fixture.controller.playPlaylist(
            fixture.playlist,
            startingAt: fixture.tracks[0],
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.controller.currentPlaylistID == nil)
        #expect(fixture.items.allSatisfy { $0.skipCount == 0 && $0.playthroughCount == 0 })
        #expect(try fixture.history().isEmpty)
    }

    @Test("correlation is rebuilt in the order the player is holding the queue")
    func correlationIsRebuiltInPlayerOrder() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)

        // Shuffled: the player now holds track 2, track 0, track 1.
        let shuffled = [fixture.musicTracks[2], fixture.musicTracks[0], fixture.musicTracks[1]]
        fixture.player.reissueEntryIDs(for: shuffled, currentIndex: 1)
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.controller.canControlPlayback)

        // Next follows the player's order, not Overplay's stored one.
        await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
    }

    @Test("a natural advance into an unhydrated re-materialized entry still credits the outgoing track")
    func naturalAdvanceIntoUnhydratedRematerializedEntryStillCreditsOutgoingTrack() async throws {
        // A rebuild can only map the entries the player has hydrated, so the
        // mapped queue is legitimately a subset of the live one. Treating
        // that subset as the whole queue aged the unmapped entry into
        // divergence, which threw the active session away before the track
        // that had just played out could be credited.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)

        let reissued = fixture.player.reissueEntryIDs(for: fixture.musicTracks, currentIndex: 0)
        fixture.player.unhydratedEntryIDs = [reissued[1]]
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.player.playbackTime = 178
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        // Track 0 plays out and the player advances into the entry it has
        // not hydrated. More ticks pass than the unresolved-entry policy
        // tolerates.
        fixture.player.advanceExternally()
        for _ in 0..<8 {
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }

        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.canSkipTracks)

        // Hydration completes. Track 0 finished, so it is a playthrough —
        // not a skip at 0s, and not nothing at all.
        fixture.player.unhydratedEntryIDs = []
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.items[0].playthroughCount == 1)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().contains { $0.eventType == .playthrough })
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.controller.currentPlaylistItem?.trackID == fixture.tracks[1].id)
        #expect(fixture.controller.canControlPlayback)
    }

    @Test("a full re-issue whose current entry stays unhydrated still credits the outgoing track")
    func fullReissueWithUnhydratedCurrentEntryStillCreditsOutgoingTrack() async throws {
        // Ownership used to need a previously mapped entry ID to still be
        // live, which a full re-materialization makes impossible. The
        // hold-off therefore never engaged, the unresolved policy diverged
        // after five ticks, and the session went with it — so the track that
        // had just played out could never be credited once the current entry
        // finally hydrated.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 178
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        let reissued = fixture.player.reissueEntryIDs(for: fixture.musicTracks, currentIndex: 1)
        fixture.player.unhydratedEntryIDs = [reissued[1]]

        // More ticks than the unresolved-entry policy tolerates. The entries
        // that did hydrate are the only evidence the player is still holding
        // Overplay's queue, and they have to be enough.
        for _ in 0..<8 {
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }

        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.canSkipTracks)

        fixture.player.unhydratedEntryIDs = []
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.items[0].playthroughCount == 1)
        #expect(fixture.items[0].skipCount == 0)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.controller.currentPlaylistItem?.trackID == fixture.tracks[1].id)
        #expect(fixture.controller.canControlPlayback)
    }

    @Test("a skip failure against a partially mapped queue is a delivery failure, not queue end")
    func skipFailureAgainstPartiallyMappedQueueIsADeliveryFailure() async throws {
        // The queue-end inference reads a position out of the mapped queue.
        // With only the playing entry mapped, that position looks final even
        // though the live queue proves two entries follow — persisting a skip
        // that never happened and swallowing the delivery failure that did.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 15
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        #expect(!fixture.controller.shuffleEnabled)

        let reissued = fixture.player.reissueEntryIDs(for: fixture.musicTracks, currentIndex: 0)
        fixture.player.unhydratedEntryIDs = [reissued[1], reissued[2]]
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        fixture.player.nextFailuresRemaining = 1
        await fixture.controller.next(settings: fixture.settings, context: fixture.context)

        #expect(fixture.controller.isDeliveryStalled)
        #expect(fixture.items[0].skipCount == 0)
        #expect(try fixture.history().isEmpty)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
    }

    @Test("a row omitted while unhydrated can still be jumped to in the live queue")
    func rowOmittedWhileUnhydratedCanStillBeJumpedToInTheLiveQueue() async throws {
        // Once the current entry was mapped, nothing rebuilt again, so an
        // entry omitted while unhydrated stayed absent until it became
        // current. CarPlay's in-queue jump then fell back to replacing the
        // queue, losing the player's ordering.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)

        let reissued = fixture.player.reissueEntryIDs(for: fixture.musicTracks, currentIndex: 0)
        fixture.player.unhydratedEntryIDs = [reissued[2]]
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let replacementsBefore = fixture.player.replaceQueueCallCount

        // Track 2's entry hydrates while track 0 is still playing, so it is
        // never the current entry.
        fixture.player.unhydratedEntryIDs = []
        let didSkip = await fixture.controller.playTrackInCurrentQueue(
            localTrackID: fixture.tracks[2].id.uuidString,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(didSkip)
        #expect(fixture.player.replaceQueueCallCount == replacementsBefore)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[2].id.rawValue)
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.canControlPlayback)
    }

    @Test("a full re-issue during a pending append still recovers the playlist")
    func fullReissueDuringPendingAppendStillRecoversPlaylist() async throws {
        // `correlateAppendedEntries` needs one previously realized entry to
        // still be live. Once a re-issue has taken them all it is stranded,
        // and deferring to it left the destructive divergence teardown as the
        // only outcome.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let added = try fixture.addPlaylist(prefix: "appended", trackCount: 1)
        fixture.context.insert(PlaylistItemRecord(
            playlistID: fixture.playlist.id,
            trackID: added.tracks[0].id,
            createdAt: .now
        ))
        try fixture.context.save()

        fixture.player.withholdsQueueItemIDs = true
        await fixture.controller.appendLiveQueueEntries(
            localTrackIDs: [added.tracks[0].id.uuidString],
            playlistID: fixture.playlist.musicPlaylistID,
            context: fixture.context
        )
        fixture.player.withholdsQueueItemIDs = false

        fixture.player.reissueEntryIDs(
            for: fixture.musicTracks + added.musicTracks,
            currentIndex: 0
        )
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.controller.canControlPlayback)

        // The appended row is part of the rebuilt queue rather than stranded.
        let didSkip = await fixture.controller.playTrackInCurrentQueue(
            localTrackID: added.tracks[0].id.uuidString,
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(didSkip)
        #expect(fixture.controller.currentTrack?.id == added.musicTracks[0].id.rawValue)
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
    }

    @Test("an external takeover is still divergence, not something to re-correlate")
    func externalTakeoverIsStillDivergence() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let external = try fixture.addPlaylist(prefix: "external", trackCount: 2)

        fixture.player.replaceQueueExternally(with: external.musicTracks)
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.currentPlaylistID == nil)
        #expect(fixture.controller.activePlaylistSnapshot == nil)
        #expect(!fixture.controller.canControlPlayback)
        // The player is still holding a queue, so track navigation is still
        // something it can do.
        #expect(fixture.controller.canSkipTracks)
        #expect(fixture.controller.remoteCommandAvailability.canSkipToNext)
        #expect(fixture.controller.remoteCommandAvailability.canSkipToPrevious)
        #expect(fixture.controller.remoteCommandAvailability.canShuffle)
    }

    @Test("track navigation is unavailable only when the player holds no queue")
    func trackNavigationIsUnavailableOnlyWithoutAPlayerQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        await fixture.controller.reconcilePlayerState(context: fixture.context)
        #expect(!fixture.controller.hasLivePlayerEntry)
        #expect(!fixture.controller.canSkipTracks)

        try await fixture.start(at: 0)
        #expect(fixture.controller.hasLivePlayerEntry)
        #expect(fixture.controller.canSkipTracks)

        fixture.player.finishQueueNaturally()
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        #expect(!fixture.controller.hasLivePlayerEntry)
        #expect(!fixture.controller.canSkipTracks)
    }

    // MARK: - Un-hydrated entries the player has made current

    @Test("an un-hydrated entry the player made current stops publishing the outgoing track")
    func unhydratedCurrentEntryStopsPublishingTheOutgoingTrack() async throws {
        // Apple Music can leave a current entry's item un-hydrated for as
        // long as Overplay is not the app in front — another CarPlay app on
        // the screen, for instance. Holding the outgoing track until it
        // catches up left the whole iPhone Now Playing screen bound to the
        // previous track.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        fixture.player.playbackTime = 178
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        #expect(fixture.controller.nowPlayingDisplayTrack?.id == fixture.musicTracks[0].id.rawValue)

        fixture.player.withholdsCurrentEntryItem = true
        fixture.player.advanceExternally()
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.nowPlayingDisplayTrack?.id == fixture.musicTracks[1].id.rawValue)
        #expect(fixture.controller.nowPlayingDisplayTrack?.title == fixture.tracks[1].title)
        #expect(fixture.controller.currentPlaylistItem?.trackID == fixture.tracks[1].id)
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.controller.canSkipTracks)

        // The outgoing track is credited exactly once, however many ticks
        // pass before the incoming item hydrates.
        #expect(fixture.items[0].playthroughCount == 1)
        #expect(fixture.items[1].playthroughCount == 0)
        for _ in 0..<3 {
            await fixture.controller.reconcilePlayerState(context: fixture.context)
        }
        #expect(fixture.items[0].playthroughCount == 1)
        #expect(fixture.controller.nowPlayingDisplayTrack?.id == fixture.musicTracks[1].id.rawValue)

        fixture.player.withholdsCurrentEntryItem = false
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        #expect(fixture.controller.nowPlayingDisplayTrack?.id == fixture.musicTracks[1].id.rawValue)
    }

    @Test("the same entry momentarily losing its item does not blank the display")
    func sameEntryLosingItsItemDoesNotBlankTheDisplay() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)

        fixture.player.withholdsCurrentEntryItem = true
        await fixture.controller.reconcilePlayerState(context: fixture.context)

        #expect(fixture.controller.nowPlayingDisplayTrack?.id == fixture.musicTracks[0].id.rawValue)
        #expect(fixture.controller.currentTrack?.id == fixture.musicTracks[0].id.rawValue)
    }

    // MARK: - Recovery from lost queue correlation

    @Test("the primary control pauses running playback when correlation is lost")
    func thePrimaryControlPausesRunningPlaybackWhenCorrelationIsLost() async throws {
        // Regression for the reported failure: with correlation gone the
        // control still renders a pause icon from `isPlaying`, but its action
        // used to fall through to "play the default playlist", restarting the
        // One True Playlist from its first track on every press.
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        fixture.player.playbackStatus = .playing
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        let replacementsBefore = fixture.player.replaceQueueCallCount

        #expect(fixture.controller.isPlaying)
        #expect(!fixture.controller.canControlPlayback)

        await fixture.controller.performPrimaryPlaybackAction(
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.player.playbackStatus == .paused)
        #expect(fixture.player.replaceQueueCallCount == replacementsBefore)
    }

    @Test("the primary control resumes a held queue instead of restarting the playlist")
    func thePrimaryControlResumesAHeldQueueWhenCorrelationIsLost() async throws {
        // Remote play is now offered for a paused queue Overplay cannot
        // describe, so it has to resume that queue. Falling through to the
        // default playlist would restart it from its first track under a
        // button that meant "resume".
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)
        let external = try fixture.addPlaylist(prefix: "external", trackCount: 2)

        fixture.player.replaceQueueExternally(with: external.musicTracks)
        await fixture.controller.reconcilePlayerState(context: fixture.context)
        fixture.controller.pause()
        let replacementsBefore = fixture.player.replaceQueueCallCount

        #expect(!fixture.controller.canControlPlayback)
        #expect(fixture.controller.canSkipTracks)
        #expect(fixture.controller.remoteCommandAvailability.canPlay)

        await fixture.controller.performPrimaryPlaybackAction(
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.player.playbackStatus == .playing)
        #expect(fixture.player.replaceQueueCallCount == replacementsBefore)
        #expect(fixture.controller.currentTrack?.id == external.musicTracks[0].id.rawValue)
    }

    @Test("the primary control still starts playback when nothing is playing")
    func thePrimaryControlStillStartsPlaybackWhenNothingIsPlaying() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        await fixture.controller.reconcilePlayerState(context: fixture.context)
        #expect(!fixture.controller.isPlaying)

        await fixture.controller.performPrimaryPlaybackAction(
            settings: fixture.settings,
            context: fixture.context
        )

        #expect(fixture.player.playbackStatus == .playing)
        #expect(fixture.player.replaceQueueCallCount == 1)
    }

    @Test("the primary control toggles normally while correlation is intact")
    func thePrimaryControlTogglesNormallyWhileCorrelationIsIntact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try await fixture.start(at: 0)

        #expect(fixture.controller.canControlPlayback)
        let replacementsAfterStart = fixture.player.replaceQueueCallCount

        await fixture.controller.performPrimaryPlaybackAction(
            settings: fixture.settings,
            context: fixture.context
        )
        #expect(fixture.player.playbackStatus == .paused)

        await fixture.controller.performPrimaryPlaybackAction(
            settings: fixture.settings,
            context: fixture.context
        )
        #expect(fixture.player.playbackStatus == .playing)
        // Toggling never rebuilds the queue.
        #expect(fixture.player.replaceQueueCallCount == replacementsAfterStart)
    }
}

@MainActor
private final class TransitionSleepProbe {
    var observedTrackIDs: [String?] = []
    var observedRestoreTrackIDs: [String?] = []
    var observedCurrentRowTrackIDs: [String?] = []
    var handler: (() -> Void)?
}

@MainActor
private final class ControllablePlaybackPlayer: PlaybackPlayer {
    func removeQueueEntries(withIDs entryIDs: Set<String>) {
        entries.removeAll { entryIDs.contains($0.id) }
    }
    enum Failure: Error {
        case commandFailed
        case queueEnded
    }

    var playbackStatus: MusicPlayer.PlaybackStatus = .stopped
    var playbackTime: TimeInterval = 0
    private(set) var prepareToPlayCallCount = 0
    private(set) var playCallCount = 0
    var playFailuresRemaining = 0
    var nextFailuresRemaining = 0
    var previousFailuresRemaining = 0
    var nextConfirmationDelays: [Int] = []
    var appendedTrackBatchSizes: [Int] = []
    var queuedEntryCount: Int { entries.count }
    var previousConfirmationDelays: [Int] = []
    var replacementConfirmationDelays: [Int] = []
    var clearCurrentEntryWhileReplacementPending = false
    var nextEntryOverride: MusicPlayer.Queue.Entry?
    var suppressCurrentEntryReporting = false
    var nextRevealsUnchangedEntry = false
    var blockNextCommand = false
    var skipToEntryFailuresRemaining = 0
    var skipToEntryConfirmationDelays: [Int] = []
    private(set) var nextCallCount = 0
    private(set) var skipToEntryCallCount = 0
    private(set) var replaceQueueCallCount = 0
    var reissuedTracksOnReplace: [Track]?

    private var entries: [MusicPlayer.Queue.Entry] = []
    private var currentEntryStorage: MusicPlayer.Queue.Entry?
    private var pendingTransition: (entry: MusicPlayer.Queue.Entry?, remainingReads: Int)?
    private var blockedNextContinuation: CheckedContinuation<Void, Never>?

    var currentEntry: MusicPlayer.Queue.Entry? {
        guard !suppressCurrentEntryReporting else { return nil }
        if let pendingTransition {
            if pendingTransition.remainingReads == 0 {
                currentEntryStorage = pendingTransition.entry
                self.pendingTransition = nil
            } else {
                self.pendingTransition?.remainingReads -= 1
            }
        }
        return currentEntryStorage
    }

    var currentEntryItem: MusicPlayer.Queue.Entry.Item? {
        guard !withholdsCurrentEntryItem, let currentEntryStorage else { return nil }
        return unhydratedEntryIDs.contains(currentEntryStorage.id) ? nil : currentEntryStorage.item
    }

    func replaceQueue(with materialization: PlaybackQueueMaterialization) {
        replaceQueueCallCount += 1
        if let reissuedTracksOnReplace {
            entries = reissuedTracksOnReplace.map { MusicPlayer.Queue.Entry($0) }
        } else {
            entries = materialization.queueEntries
        }
        let requestedTarget = materialization.startingEntry ?? materialization.queueEntries.first
        let target = if reissuedTracksOnReplace != nil,
                        let musicItemID = requestedTarget?.item?.id.rawValue {
            entries.first { $0.item?.id.rawValue == musicItemID }
        } else {
            requestedTarget
        }
        let delay = replacementConfirmationDelays.isEmpty ? 0 : replacementConfirmationDelays.removeFirst()
        if delay > 0, clearCurrentEntryWhileReplacementPending {
            currentEntryStorage = nil
        }
        scheduleTransition(to: target, afterReads: delay)
    }

    func prepareToPlay() async throws {
        prepareToPlayCallCount += 1
        if let onPrepareToPlay {
            self.onPrepareToPlay = nil
            await onPrepareToPlay()
        }
    }

    func play() async throws {
        playCallCount += 1
        if let onPlay {
            self.onPlay = nil
            await onPlay()
        }
        if playFailuresRemaining > 0 {
            playFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        playbackStatus = .playing
    }

    func pause() {
        playbackStatus = .paused
    }

    func skipToNextEntry() async throws {
        nextCallCount += 1
        if blockNextCommand {
            await withCheckedContinuation { continuation in
                blockedNextContinuation = continuation
            }
            blockNextCommand = false
        }
        if nextFailuresRemaining > 0 {
            nextFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        if nextRevealsUnchangedEntry {
            nextRevealsUnchangedEntry = false
            suppressCurrentEntryReporting = false
            return
        }
        if let nextEntryOverride {
            self.nextEntryOverride = nil
            scheduleTransition(to: nextEntryOverride, afterReads: 0)
            return
        }
        guard let currentEntryStorage,
              let index = entries.firstIndex(where: { $0.id == currentEntryStorage.id }),
              entries.indices.contains(index + 1) else {
            self.currentEntryStorage = nil
            playbackStatus = .stopped
            throw Failure.queueEnded
        }
        let delay = nextConfirmationDelays.isEmpty ? 0 : nextConfirmationDelays.removeFirst()
        scheduleTransition(to: entries[index + 1], afterReads: delay)
    }

    func skipToPreviousEntry() async throws {
        if previousFailuresRemaining > 0 {
            previousFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        guard let currentEntryStorage,
              let index = entries.firstIndex(where: { $0.id == currentEntryStorage.id }),
              entries.indices.contains(index - 1) else {
            throw Failure.commandFailed
        }
        let delay = previousConfirmationDelays.isEmpty ? 0 : previousConfirmationDelays.removeFirst()
        scheduleTransition(to: entries[index - 1], afterReads: delay)
    }

    func skipToEntry(withID entryID: String) async throws {
        // Counted as an attempt, so a test can tell "never tried" from
        // "tried and was rejected".
        skipToEntryCallCount += 1
        if skipToEntryFailuresRemaining > 0 {
            skipToEntryFailuresRemaining -= 1
            throw Failure.commandFailed
        }
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw PlaybackQueueEntryError.entryNotInQueue
        }
        let delay = skipToEntryConfirmationDelays.isEmpty ? 0 : skipToEntryConfirmationDelays.removeFirst()
        scheduleTransition(to: entry, afterReads: delay)
    }

    func appendToQueue(_ tracks: [Track]) async throws {
        appendedTrackBatchSizes.append(tracks.count)
        entries.append(contentsOf: tracks.map { MusicPlayer.Queue.Entry($0) })
        if let onAppendToQueue {
            self.onAppendToQueue = nil
            await onAppendToQueue()
        }
    }

    /// Simulates Apple Music reporting queue entries before their items
    /// hydrate, which the real player does for entries it materializes.
    var withholdsQueueItemIDs = false
    /// Simulates the same hydration delay on the already-current entry.
    var withholdsCurrentEntryItem = false
    /// Entries Apple Music has made part of the queue but has not hydrated,
    /// so a re-materialized queue can hydrate one entry at a time.
    var unhydratedEntryIDs: Set<String> = []
    /// Runs while an append is in flight, so tests can reproduce the queue
    /// being replaced underneath a top-up.
    var onAppendToQueue: (() async -> Void)?
    /// Runs inside `prepareToPlay()`, so tests can reproduce an interruption
    /// arriving while automatic recovery is suspended in MusicKit.
    var onPrepareToPlay: (() async -> Void)?
    /// Runs inside `play()`, which the controller awaits while a transition is
    /// still in flight, so tests can act on a concurrent surface mid-transition.
    var onPlay: (() async -> Void)?

    var queueEntrySnapshots: [PlayerQueueEntrySnapshot] {
        entries.map { entry in
            let isUnhydrated = withholdsQueueItemIDs || unhydratedEntryIDs.contains(entry.id)
            return PlayerQueueEntrySnapshot(
                id: entry.id,
                musicItemID: isUnhydrated ? nil : entry.item?.id.rawValue
            )
        }
    }

    var reportedShuffleMode: MusicPlayer.ShuffleMode? = .off
    var reportedRepeatMode: MusicPlayer.RepeatMode? = MusicPlayer.RepeatMode.none

    var shuffleMode: MusicPlayer.ShuffleMode {
        get { reportedShuffleMode ?? .off }
        set { reportedShuffleMode = newValue }
    }

    var repeatMode: MusicPlayer.RepeatMode {
        get { reportedRepeatMode ?? MusicPlayer.RepeatMode.none }
        set { reportedRepeatMode = newValue }
    }

    func releaseBlockedNextCommand() {
        blockedNextContinuation?.resume()
        blockedNextContinuation = nil
    }

    func advanceExternally() {
        guard let currentEntryStorage,
              let index = entries.firstIndex(where: { $0.id == currentEntryStorage.id }),
              entries.indices.contains(index + 1) else { return }
        scheduleTransition(to: entries[index + 1], afterReads: 0)
        _ = currentEntry
        playbackTime = 0
    }

    /// Apple Music re-materializing the queue it already holds under fresh
    /// entry IDs, which is what a shuffle-mode change does to a loaded
    /// queue. Same tracks, same playlist, entry IDs Overplay never minted.
    @discardableResult
    func reissueEntryIDs(for tracks: [Track], currentIndex: Int) -> [String] {
        entries = tracks.map { MusicPlayer.Queue.Entry($0) }
        pendingTransition = nil
        currentEntryStorage = entries.indices.contains(currentIndex) ? entries[currentIndex] : entries.first
        return entries.map(\.id)
    }

    /// Another Now Playing origin replacing the queue Overplay handed over.
    func replaceQueueExternally(with tracks: [Track]) {
        entries = tracks.map { MusicPlayer.Queue.Entry($0) }
        pendingTransition = nil
        currentEntryStorage = entries.first
    }

    func finishQueueNaturally() {
        currentEntryStorage = nil
        pendingTransition = nil
        playbackStatus = .stopped
    }

    private func scheduleTransition(to entry: MusicPlayer.Queue.Entry?, afterReads: Int) {
        if afterReads == 0 {
            currentEntryStorage = entry
            pendingTransition = nil
        } else {
            pendingTransition = (entry, afterReads)
        }
        playbackTime = 0
    }
}

@MainActor
private struct EmptyMusicLibraryPlaybackHistoryFetcher: MusicLibraryPlaybackHistoryFetching {
    func snapshots(
        for candidates: [MusicLibraryPlaybackCandidate]
    ) async throws -> [String: MusicLibraryPlaybackSnapshot] {
        _ = candidates
        return [:]
    }
}

private enum ReconciliationTestFailure: Error {
    case expected
}

@MainActor
private struct PlaybackTransitionFixture {
    struct AddedPlaylist {
        var playlist: PlaylistRecord
        var tracks: [TrackRecord]
        var items: [PlaylistItemRecord]
        var musicTracks: [Track]
    }

    var container: ModelContainer
    var context: ModelContext
    var playlist: PlaylistRecord
    var tracks: [TrackRecord]
    var items: [PlaylistItemRecord]
    var musicTracks: [Track]
    var settings: OverplaySettings
    var player: ControllablePlaybackPlayer
    var controller: PlaybackController
    var sleepProbe: TransitionSleepProbe
    var playerID: String

    func start(at index: Int) async throws {
        await controller.playPlaylist(
            playlist,
            startingAt: tracks[index],
            settings: settings,
            context: context
        )
        #expect(controller.currentTrack?.id == musicTracks[index].id.rawValue)
    }

    func history() throws -> [HistoryEvent] {
        try context.fetch(FetchDescriptor<HistoryEvent>())
    }

    func addPlaylist(prefix: String, trackCount: Int) throws -> AddedPlaylist {
        let added = try Self.insertPlaylist(prefix: prefix, trackCount: trackCount, context: context)
        try context.save()
        return added
    }

    func cleanUp() {
        PlaybackOrderStore.clear(
            playerID: playerID,
            musicPlaylistID: playlist.musicPlaylistID,
            flushImmediately: true
        )
        LocalPlaybackStateStore.clear(flushImmediately: true)
        PlaybackWaypointStore.clear(flushImmediately: true)
    }

    static func insertPlaylist(
        prefix: String,
        trackCount: Int,
        context: ModelContext
    ) throws -> AddedPlaylist {
        let playlist = PlaylistRecord(
            musicPlaylistID: "\(prefix)-playlist-\(UUID().uuidString)",
            name: prefix
        )
        context.insert(playlist)
        var tracks: [TrackRecord] = []
        var items: [PlaylistItemRecord] = []
        var musicTracks: [Track] = []
        for index in 0..<trackCount {
            let musicTrack = try makeMusicTrack(id: "\(prefix)-music-\(index)", title: "\(prefix) \(index)")
            let track = TrackRecord(
                catalogID: musicTrack.id.rawValue,
                libraryID: musicTrack.id.rawValue,
                title: musicTrack.title,
                artistName: musicTrack.artistName,
                durationSeconds: 180,
                musicKitPlaybackData: try JSONEncoder().encode(musicTrack),
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            let item = PlaylistItemRecord(
                playlistID: playlist.id,
                trackID: track.id,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            context.insert(track)
            context.insert(item)
            tracks.append(track)
            items.append(item)
            musicTracks.append(musicTrack)
        }
        return AddedPlaylist(playlist: playlist, tracks: tracks, items: items, musicTracks: musicTracks)
    }

    private static func makeMusicTrack(id: String, title: String) throws -> Track {
        let data = """
        {
          "id": "\(id)",
          "type": "songs",
          "attributes": {
            "albumName": "Album",
            "artistName": "Artist",
            "durationInMillis": 180000,
            "genreNames": [],
            "name": "\(title)",
            "trackNumber": 1
          }
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(Track.self, from: data)
    }
}

@MainActor
private func makeFixture(
    maximumObservationCount: Int = 5,
    trackCount: Int = 3
) throws -> PlaybackTransitionFixture {
    LocalPlaybackStateStore.clear(flushImmediately: true)
    let container = try OverplayTestSupport.makeModelContainer()
    let context = container.mainContext
    let added = try PlaybackTransitionFixture.insertPlaylist(prefix: "main", trackCount: trackCount, context: context)
    added.playlist.role = .oneTruePlaylist
    let settings = OverplaySettings(
        selectedPlaylistID: added.playlist.musicPlaylistID,
        selectedPlaylistName: added.playlist.name,
        skipThresholdPercentage: 50,
        minimumSkipListeningSeconds: 0,
        playthroughThresholdPercentage: 100
    )
    context.insert(settings)
    try context.save()

    let player = ControllablePlaybackPlayer()
    let sleepProbe = TransitionSleepProbe()
    let playerID = "transition-tests-\(UUID().uuidString)"
    let controller = PlaybackController(
        playerID: playerID,
        player: player,
        transitionConfirmationPolicy: PlaybackTransitionConfirmationPolicy(
            maximumObservationCount: maximumObservationCount,
            observationInterval: .zero
        ),
        sleepForTransitionConfirmation: { _ in
            sleepProbe.handler?()
            await Task.yield()
        }
    )
    return PlaybackTransitionFixture(
        container: container,
        context: context,
        playlist: added.playlist,
        tracks: added.tracks,
        items: added.items,
        musicTracks: added.musicTracks,
        settings: settings,
        player: player,
        controller: controller,
        sleepProbe: sleepProbe,
        playerID: playerID
    )
}
