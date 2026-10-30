import Foundation

nonisolated enum PlaylistCollageLayout: String, CaseIterable, Codable, Identifiable {
    case pile, grid3, grid8
    var id: Self { self }
    var title: String {
        switch self {
        case .pile: "Pile"
        case .grid3: "3 × 3 Grid"
        case .grid8: "8 × 8 Grid"
        }
    }
}

nonisolated enum PlaylistCollageStroke: String, CaseIterable, Codable, Identifiable {
    case none, black, white
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Normalized coordinates keep both placement and border width independent of resolution.
nonisolated struct PlaylistCollage: Codable, Equatable {
    struct Cover: Equatable {
        let url: String
        let latestDate: Date
        var plays: Int = 0
        /// The latest play of any song with this cover: breaks a tie in plays.
        var lastPlayed: Date = .distantPast
    }

    struct Placement: Codable, Equatable {
        let url: String
        let x: Double
        let y: Double
        let side: Double
        let rotation: Double
        var strokeWidth: Double { side * 0.015 }
    }

    let id: UUID
    let generatedAt: Date
    let layout: PlaylistCollageLayout
    let stroke: PlaylistCollageStroke
    let placements: [Placement]
    /// Invalidate older compositions: 2 added role-specific artwork ranking,
    /// 3 draws each pile cover at most once, 4 puts the runners-up in the
    /// corners.
    var orderingVersion: Int? = 4

    func needsRefresh(at date: Date, layout: PlaylistCollageLayout, stroke: PlaylistCollageStroke) -> Bool {
        orderingVersion != 4 || self.layout != layout || self.stroke != stroke || date.timeIntervalSince(generatedAt) >= 86_400
    }

    @MainActor static func covers(
        playlistID: UUID, items: [PlaylistItemRecord], tracks: [TrackRecord],
        scope: PlaylistPlaybackScope = .active
    ) -> [Cover] {
        let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var latestDates: [String: Date] = [:]
        var plays: [String: Int] = [:]
        var lastPlayed: [String: Date] = [:]
        for item in items where item.playlistID == playlistID && scope.includes(item) {
            guard let url = tracksByID[item.trackID]?.artworkURLTemplate, !url.isEmpty else { continue }
            let date = PlaylistDisplayOrder.recencyDate(for: item, scope: scope)
            latestDates[url] = max(latestDates[url] ?? .distantPast, date)
            plays[url, default: 0] += item.playthroughCount
            if let played = item.lastPlayedAt { lastPlayed[url] = max(lastPlayed[url] ?? .distantPast, played) }
        }
        return latestDates.map {
            Cover(url: $0.key, latestDate: $0.value, plays: plays[$0.key, default: 0],
                  lastPlayed: lastPlayed[$0.key] ?? .distantPast)
        }
            .sorted { $0.latestDate == $1.latestDate ? $0.url < $1.url : $0.latestDate < $1.latestDate }
    }

    /// Rank by recency or summed Overplay plays. Store the arrangement, not just a seed,
    /// so later membership changes cannot rearrange an existing daily image.
    static func make<R: RandomNumberGenerator>(
        covers: [Cover], layout: PlaylistCollageLayout, stroke: PlaylistCollageStroke,
        rankByPlayCount: Bool = false, at date: Date = .now, using random: inout R
    ) -> Self {
        // Swift sorting is stable: shuffling first randomizes equal-rank choices.
        // Equal plays go to the most recently played, so the top cover changes
        // only when something is played.
        let covers = covers.shuffled(using: &random).sorted {
            guard rankByPlayCount else { return $0.latestDate < $1.latestDate }
            return $0.plays == $1.plays ? $0.lastPlayed < $1.lastPlayed : $0.plays < $1.plays
        }
        var placements: [Placement] = []
        if !covers.isEmpty {
            if layout == .pile {
                // The newest cover is featured last, centred on top.
                let featured = covers[covers.count - 1]
                let earlier = covers.count > 1 ? Array(covers.dropLast()) : covers
                // The next four, one to each corner, show past the featured one.
                let runnersUp = covers.count > 1 ? Array(earlier.suffix(4)) : []
                // A 5 × 5 overlapping underlay covers every point, even at ±3°.
                // The earliest covers fill it once each, the 16 edge cells first.
                // A cover repeats only when there are too few to fill it.
                let cells = (0..<25).map { (column: $0 % 5, row: $0 / 5) }
                let onEdge = { (cell: (column: Int, row: Int)) in
                    cell.column == 0 || cell.column == 4 || cell.row == 0 || cell.row == 4
                }
                let underlay = cells.filter(onEdge).shuffled(using: &random)
                    + cells.filter { !onEdge($0) }.shuffled(using: &random)
                for (index, cell) in underlay.enumerated() {
                    placements.append(Placement(
                        url: earlier[index % earlier.count].url,
                        x: Double(cell.column) / 4, y: Double(cell.row) / 4,
                        side: Double.random(in: 0.30...0.60, using: &random),
                        rotation: Double.random(in: -3...3, using: &random)
                    ))
                }
                // Every remaining cover once, at a random size and position.
                for cover in earlier.dropLast(runnersUp.count).dropFirst(underlay.count) {
                    let side = Double.random(in: 0.30...0.60, using: &random)
                    let rotation = Double.random(in: -3...3, using: &random)
                    let radians = rotation * .pi / 180
                    // Include the rotated corners when keeping covers within the canvas.
                    let margin = side * (abs(cos(radians)) + abs(sin(radians))) / 2
                    placements.append(Placement(
                        url: cover.url,
                        x: Double.random(in: margin...(1 - margin), using: &random),
                        y: Double.random(in: margin...(1 - margin), using: &random),
                        side: side, rotation: rotation
                    ))
                }
                // NW, NE, SW and SE, dealt at random; the higher ranked drawn later.
                let corners = [(x: 0.25, y: 0.25), (x: 0.75, y: 0.25), (x: 0.25, y: 0.75), (x: 0.75, y: 0.75)]
                    .shuffled(using: &random)
                for (cover, corner) in zip(runnersUp, corners) {
                    let side = Double.random(in: 0.36...0.44, using: &random)
                    let rotation = Double.random(in: -3...3, using: &random)
                    let radians = rotation * .pi / 180
                    let margin = side * (abs(cos(radians)) + abs(sin(radians))) / 2
                    let x = corner.x + Double.random(in: -0.04...0.04, using: &random)
                    let y = corner.y + Double.random(in: -0.04...0.04, using: &random)
                    placements.append(Placement(
                        url: cover.url,
                        x: min(max(x, margin), 1 - margin), y: min(max(y, margin), 1 - margin),
                        side: side, rotation: rotation
                    ))
                }
                placements.append(Placement(
                    url: featured.url, x: 0.5, y: 0.5, side: 0.50,
                    rotation: Double.random(in: -3...3, using: &random)
                ))
            } else {
                let dimension = layout == .grid3 ? 3 : 8
                let count = dimension * dimension
                let selected = Array(covers.suffix(count))
                let cells = (0..<count).map { selected[$0 % selected.count] }.shuffled(using: &random)
                for (index, cover) in cells.enumerated() {
                    placements.append(Placement(
                        url: cover.url,
                        x: (Double(index % dimension) + 0.5) / Double(dimension),
                        y: (Double(index / dimension) + 0.5) / Double(dimension),
                        side: 1 / Double(dimension), rotation: 0
                    ))
                }
            }
        }
        return Self(id: UUID(), generatedAt: date, layout: layout, stroke: stroke, placements: placements)
    }
}
