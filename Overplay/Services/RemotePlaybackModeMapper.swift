import MediaPlayer
@preconcurrency import MusicKit

enum RemotePlaybackModeMapper {
    static func repeatType(for repeatMode: MusicKit.MusicPlayer.RepeatMode) -> MPRepeatType {
        switch repeatMode {
        case .one:
            .one
        case .all:
            .all
        default:
            .off
        }
    }

    static func repeatMode(for repeatType: MPRepeatType) -> MusicKit.MusicPlayer.RepeatMode {
        switch repeatType {
        case .one:
            .one
        case .all:
            .all
        default:
            .none
        }
    }
}
