import MediaPlayer
@preconcurrency import MusicKit

enum RemotePlaybackModeMapper {
    static func shuffleType(for shuffleEnabled: Bool) -> MPShuffleType {
        shuffleEnabled ? .items : .off
    }

    static func shuffleEnabled(for shuffleType: MPShuffleType) -> Bool {
        canonicalShuffleType(for: shuffleType) != .off
    }

    static func canonicalShuffleType(for shuffleType: MPShuffleType) -> MPShuffleType {
        switch shuffleType {
        case .off:
            .off
        default:
            .items
        }
    }
}

extension RemotePlaybackModeMapper {
    /// MusicKit and MediaPlayer describe repeat with different types, and the
    /// system control speaks the MediaPlayer one.
    static func repeatType(for repeatMode: MusicKit.MusicPlayer.RepeatMode) -> MPRepeatType {
        switch repeatMode {
        case .all: .all
        case .one: .one
        default: .off
        }
    }

    static func repeatMode(for repeatType: MPRepeatType) -> MusicKit.MusicPlayer.RepeatMode {
        switch repeatType {
        case .all: .all
        case .one: .one
        default: MusicKit.MusicPlayer.RepeatMode.none
        }
    }
}
