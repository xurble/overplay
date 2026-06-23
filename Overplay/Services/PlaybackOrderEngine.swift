import Foundation

struct PlaybackOrderTrack: Equatable, Sendable {
    var id: String
    var createdAt: Date
    var isPlayable: Bool

    init(id: String, createdAt: Date, isPlayable: Bool = true) {
        self.id = id
        self.createdAt = createdAt
        self.isPlayable = isPlayable
    }
}

enum PlaybackOrderEngine {
    static func normalOrder(for tracks: [PlaybackOrderTrack], includeUnplayableTrackID: String? = nil) -> [String] {
        uniqueIDs(ordered(tracks)
            .filter { $0.isPlayable || $0.id == includeUnplayableTrackID }
            .map(\.id))
    }

    static func reshuffledOrder(
        for tracks: [PlaybackOrderTrack],
        avoiding avoidedTrackID: String?,
        randomize: ([String]) -> [String] = { $0.shuffled() }
    ) -> [String] {
        let playableIDs = normalOrder(for: tracks)
        guard playableIDs.count > 1 else {
            return playableIDs
        }

        guard let avoidedTrackID, playableIDs.contains(avoidedTrackID) else {
            return randomize(playableIDs)
        }

        let remainingIDs = randomize(playableIDs.filter { $0 != avoidedTrackID })
        guard playableIDs.count > 5 else {
            return remainingIDs + [avoidedTrackID]
        }

        let insertionIndex = min(5, remainingIDs.count)
        return Array(remainingIDs.prefix(insertionIndex))
            + [avoidedTrackID]
            + Array(remainingIDs.dropFirst(insertionIndex))
    }

    static func reconciledOrder(
        storedOrder: [String],
        tracks: [PlaybackOrderTrack],
        includeUnplayableTrackID: String? = nil
    ) -> [String] {
        let availableIDs = normalOrder(for: tracks, includeUnplayableTrackID: includeUnplayableTrackID)
        guard !storedOrder.isEmpty else {
            return availableIDs
        }

        let availableSet = Set(availableIDs)
        var reconciled = uniqueIDs(storedOrder).filter { availableSet.contains($0) }
        let existingSet = Set(reconciled)
        reconciled.append(contentsOf: availableIDs.filter { !existingSet.contains($0) })
        return reconciled
    }

    static func displayOrder(
        for tracks: [PlaybackOrderTrack],
        storedOrder: [String]
    ) -> [String] {
        guard !storedOrder.isEmpty else {
            return ordered(tracks).map(\.id)
        }

        let storedIndex = storedOrder.enumerated().firstValueDictionary(
            keyedBy: \.element,
            value: \.offset
        )
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

    static func adjacentAvailableID(
        to trackID: String,
        in orderedIDs: [String],
        availableIDs: Set<String>,
        movingForward: Bool
    ) -> String? {
        guard let index = orderedIDs.firstIndex(of: trackID) else {
            return nil
        }

        let candidates: [String] = if movingForward {
            Array(orderedIDs[orderedIDs.index(after: index)...])
        } else {
            Array(orderedIDs[..<index].reversed())
        }

        return candidates.first { availableIDs.contains($0) }
    }

    private static func ordered(_ tracks: [PlaybackOrderTrack]) -> [PlaybackOrderTrack] {
        tracks.sorted(by: normalPrecedes)
    }

    private static func normalPrecedes(_ left: PlaybackOrderTrack, _ right: PlaybackOrderTrack) -> Bool {
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id < right.id
    }

    private static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
