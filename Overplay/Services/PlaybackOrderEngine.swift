import Foundation

struct PlaybackOrderTrack: Equatable, Sendable {
    var id: String
    var sortOrder: Int
    var createdAt: Date
    var isPlayable: Bool

    init(id: String, sortOrder: Int, createdAt: Date, isPlayable: Bool = true) {
        self.id = id
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.isPlayable = isPlayable
    }
}

enum PlaybackOrderEngine {
    static func normalOrder(for tracks: [PlaybackOrderTrack], includeUnplayableTrackID: String? = nil) -> [String] {
        ordered(tracks)
            .filter { $0.isPlayable || $0.id == includeUnplayableTrackID }
            .map(\.id)
    }

    static func shuffleOrder(
        for tracks: [PlaybackOrderTrack],
        currentTrackID: String?,
        randomize: ([String]) -> [String] = { $0.shuffled() }
    ) -> [String] {
        let playableIDs = normalOrder(for: tracks)
        guard playableIDs.count > 2 else {
            return playableIDs
        }

        guard let currentTrackID, playableIDs.contains(currentTrackID) else {
            return randomize(playableIDs)
        }

        return [currentTrackID] + randomize(playableIDs.filter { $0 != currentTrackID })
    }

    static func reconciledShuffleOrder(
        storedOrder: [String],
        tracks: [PlaybackOrderTrack],
        currentTrackID: String?
    ) -> [String] {
        let playableIDs = normalOrder(for: tracks)
        guard playableIDs.count > 2 else {
            return playableIDs
        }

        let playableSet = Set(playableIDs)
        var reconciled = storedOrder.filter { playableSet.contains($0) || $0 == currentTrackID }
        let existingSet = Set(reconciled)
        reconciled.append(contentsOf: playableIDs.filter { !existingSet.contains($0) })
        return reconciled
    }

    static func repeatShuffleOrder(
        for tracks: [PlaybackOrderTrack],
        lastPlayedTrackID: String,
        randomize: ([String]) -> [String] = { $0.shuffled() }
    ) -> [String] {
        let playableIDs = normalOrder(for: tracks)
        guard playableIDs.count > 2 else {
            return playableIDs
        }

        let remainingIDs = randomize(playableIDs.filter { $0 != lastPlayedTrackID })
        guard playableIDs.contains(lastPlayedTrackID) else {
            return randomize(playableIDs)
        }

        if playableIDs.count <= 5 {
            return remainingIDs + [lastPlayedTrackID]
        }

        let insertionIndex = min(5, remainingIDs.count)
        return Array(remainingIDs.prefix(insertionIndex)) + [lastPlayedTrackID] + Array(remainingIDs.dropFirst(insertionIndex))
    }

    static func displayOrder(
        for tracks: [PlaybackOrderTrack],
        storedOrder: [String],
        shuffleEnabled: Bool
    ) -> [String] {
        guard shuffleEnabled, !storedOrder.isEmpty else {
            return ordered(tracks).map(\.id)
        }

        let storedIndex = Dictionary(uniqueKeysWithValues: storedOrder.enumerated().map { ($0.element, $0.offset) })
        return ordered(tracks).sorted { left, right in
            switch (storedIndex[left.id], storedIndex[right.id]) {
            case let (leftIndex?, rightIndex?):
                return leftIndex < rightIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return normalPrecedes(left, right)
            }
        }.map(\.id)
    }

    private static func ordered(_ tracks: [PlaybackOrderTrack]) -> [PlaybackOrderTrack] {
        tracks.sorted(by: normalPrecedes)
    }

    private static func normalPrecedes(_ left: PlaybackOrderTrack, _ right: PlaybackOrderTrack) -> Bool {
        if left.sortOrder != right.sortOrder {
            return left.sortOrder < right.sortOrder
        }
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id < right.id
    }
}
