import Foundation
@preconcurrency import MusicKit

/// Decides whether Overplay's MusicKit playback modes actually need writing.
///
/// `MusicPlayer.State` is the shared, out-of-process player state that the
/// Music app owns, so every assignment to `shuffleMode` or `repeatMode`
/// reaches the same surface the system-wide Apple Music failures are being
/// investigated on. Overplay owns playback order and therefore holds both
/// modes off for the life of the app, which means almost every one of those
/// writes sets a value that is already set.
enum PlaybackModeResetPolicy {
    /// A nil mode means MusicKit has not reported one yet. That is not
    /// evidence the modes are already off, so it is treated as needing the
    /// write — being wrong in that direction costs one redundant assignment,
    /// whereas the other direction leaves shuffle on over Overplay's order.
    static func needsReset(
        shuffleMode: MusicPlayer.ShuffleMode?,
        repeatMode: MusicPlayer.RepeatMode?
    ) -> Bool {
        // `MusicPlayer.RepeatMode.none` is spelled out because a bare `.none`
        // against an optional resolves to `Optional.none`, which would compare
        // the wrong thing entirely.
        shuffleMode != .off || repeatMode != MusicPlayer.RepeatMode.none
    }
}
