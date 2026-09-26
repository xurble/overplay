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
    /// Invalidate compositions from before role-specific artwork ranking.
    var orderingVersion: Int? = 2

    func needsRefresh(at date: Date, layout: PlaylistCollageLayout, stroke: PlaylistCollageStroke) -> Bool {
        orderingVersion != 2 || self.layout != layout || self.stroke != stroke || date.timeIntervalSince(generatedAt) >= 86_400
    }

    @MainActor static func covers(
        playlistID: UUID, items: [PlaylistItemRecord], tracks: [TrackRecord],
        scope: PlaylistPlaybackScope = .active
    ) -> [Cover] {
        let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var latestDates: [String: Date] = [:]
        var plays: [String: Int] = [:]
        for item in items where item.playlistID == playlistID && scope.includes(item) {
            guard let url = tracksByID[item.trackID]?.artworkURLTemplate, !url.isEmpty else { continue }
            let date = PlaylistDisplayOrder.recencyDate(for: item, scope: scope)
            latestDates[url] = max(latestDates[url] ?? .distantPast, date)
            plays[url, default: 0] += item.playthroughCount
        }
        return latestDates.map { Cover(url: $0.key, latestDate: $0.value, plays: plays[$0.key, default: 0]) }
            .sorted { $0.latestDate == $1.latestDate ? $0.url < $1.url : $0.latestDate < $1.latestDate }
    }

    /// Rank by recency or summed Overplay plays. Store the arrangement, not just a seed,
    /// so later membership changes cannot rearrange an existing daily image.
    static func make<R: RandomNumberGenerator>(
        covers: [Cover], layout: PlaylistCollageLayout, stroke: PlaylistCollageStroke,
        rankByPlayCount: Bool = false, at date: Date = .now, using random: inout R
    ) -> Self {
        // Swift sorting is stable: shuffling first randomizes equal-rank choices.
        let covers = covers.shuffled(using: &random).sorted {
            rankByPlayCount ? $0.plays < $1.plays : $0.latestDate < $1.latestDate
        }
        var placements: [Placement] = []
        if !covers.isEmpty {
            if layout == .pile {
                // 5 × 5 overlapping underlay: even at ±3°, every point is covered.
                // Repeat the lowest-ranked covers here only, including outside the crop.
                let background = Array(covers.prefix(5))
                for row in 0..<5 {
                    for column in 0..<5 {
                        placements.append(Placement(
                            url: background[(row * 5 + column) % background.count].url,
                            x: Double(column) / 4, y: Double(row) / 4,
                            side: Double.random(in: 0.30...0.60, using: &random),
                            rotation: Double.random(in: -3...3, using: &random)
                        ))
                    }
                }
                for (index, cover) in covers.enumerated() {
                    let last = index == covers.count - 1
                    let side = last ? 0.50 : Double.random(in: 0.30...0.60, using: &random)
                    let rotation = Double.random(in: -3...3, using: &random)
                    let radians = rotation * .pi / 180
                    // Include the rotated corners when keeping covers within the canvas.
                    let margin = side * (abs(cos(radians)) + abs(sin(radians))) / 2
                    placements.append(Placement(
                        url: cover.url,
                        x: last ? 0.5 : Double.random(in: margin...(1 - margin), using: &random),
                        y: last ? 0.5 : Double.random(in: margin...(1 - margin), using: &random),
                        side: side, rotation: rotation
                    ))
                }
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
