import MediaPlayer
@preconcurrency import MusicKit

enum RemotePlaybackModeMapper {
    static func shuffleType(for shuffleEnabled: Bool) -> MPShuffleType {
        shuffleEnabled ? .items : .off
    }

    static func shuffleEnabled(for shuffleType: MPShuffleType) -> Bool {
        switch shuffleType {
        case .items, .collections:
            true
        default:
            false
        }
    }

    static func repeatType(for repeatEnabled: Bool) -> MPRepeatType {
        repeatEnabled ? .all : .off
    }

    static func repeatEnabled(for repeatType: MPRepeatType) -> Bool {
        repeatType != .off
    }

    static func repeatType(for repeatMode: MusicKit.MusicPlayer.RepeatMode) -> MPRepeatType {
        switch repeatMode {
        case .all:
            .all
        default:
            .off
        }
    }

    static func repeatMode(for repeatType: MPRepeatType) -> MusicKit.MusicPlayer.RepeatMode {
        switch repeatType {
        case .all:
            .all
        default:
            .none
        }
    }
}
