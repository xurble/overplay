import MediaPlayer

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
