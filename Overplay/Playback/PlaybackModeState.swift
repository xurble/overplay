import MusicKit

/// Confirmed presentation values for one playback session. An absent report
/// carries no new information; it must never manufacture a mode command.
struct PlaybackModeState: Equatable {
    var shuffle: MusicPlayer.ShuffleMode?
    var repeatMode: MusicPlayer.RepeatMode?

    mutating func observe(shuffle: MusicPlayer.ShuffleMode?, repeatMode: MusicPlayer.RepeatMode?) {
        if let shuffle { self.shuffle = shuffle }
        if let repeatMode { self.repeatMode = repeatMode }
    }
}
