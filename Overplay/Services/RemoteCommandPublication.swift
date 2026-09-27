import MediaPlayer
import MusicKit

/// The actual writes to the system, also used by tests to assert the complete
/// publication sequence (including the absence of redundant writes).
enum RemoteCommandPublication: Equatable {
    enum Command: CaseIterable, Equatable {
        case play, pause, toggle, next, previous, shuffle, repeatMode
    }
    case availability(Command, Bool)
    case shuffle(MusicKit.MusicPlayer.ShuffleMode)
    case repeatMode(MusicKit.MusicPlayer.RepeatMode)

    @MainActor func apply() {
        let center = MPRemoteCommandCenter.shared()
        switch self {
        case .availability(let command, let enabled):
            let target: MPRemoteCommand = switch command {
            case .play: center.playCommand
            case .pause: center.pauseCommand
            case .toggle: center.togglePlayPauseCommand
            case .next: center.nextTrackCommand
            case .previous: center.previousTrackCommand
            case .shuffle: center.changeShuffleModeCommand
            case .repeatMode: center.changeRepeatModeCommand
            }
            target.isEnabled = enabled
        case .shuffle(let mode):
            center.changeShuffleModeCommand.currentShuffleType = RemotePlaybackModeMapper.shuffleType(for: mode != .off)
        case .repeatMode(let mode):
            center.changeRepeatModeCommand.currentRepeatType = RemotePlaybackModeMapper.repeatType(for: mode)
        }
    }
}
