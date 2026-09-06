import Foundation

/// Caps how much of a playlist Overplay hands to the out-of-process Apple
/// Music player in one go.
///
/// Replacing `player.queue` with a whole playlist is the largest single
/// payload the app sends MusicKit, and the One True Playlist is expected to
/// grow without bound. Playback instead starts with a window and tops it up as
/// the window drains, so queue hand-off cost stays flat as the playlist grows.
///
/// Entries before the starting track are deliberately dropped rather than
/// windowed around: starting a playlist part-way through queues from there, the
/// same way Apple Music does.
struct PlaybackQueueWindowPolicy: Equatable, Sendable {
    static let standard = PlaybackQueueWindowPolicy(
        windowSize: 50,
        topUpThreshold: 15,
        topUpBatchSize: 25
    )

    /// Entries handed over when playback starts.
    var windowSize: Int
    /// Once this many or fewer entries remain ahead of the current one, top up.
    var topUpThreshold: Int
    /// Entries appended per top-up.
    var topUpBatchSize: Int

    /// Splits an ordered entry list into the slice to hand over now and the
    /// tail to hold back for later top-ups.
    func split(entryCount: Int, startIndex: Int) -> (delivered: Range<Int>, pending: Range<Int>) {
        guard entryCount > 0 else {
            return (0..<0, 0..<0)
        }

        let lowerBound = min(max(startIndex, 0), entryCount - 1)
        let upperBound = min(lowerBound + max(windowSize, 1), entryCount)
        return (lowerBound..<upperBound, upperBound..<entryCount)
    }

    /// How many held-back entries to append now. Zero means the player still
    /// holds enough of the queue.
    func topUpCount(remainingAhead: Int, pendingCount: Int) -> Int {
        guard pendingCount > 0, remainingAhead <= topUpThreshold else {
            return 0
        }

        return min(max(topUpBatchSize, 1), pendingCount)
    }
}
