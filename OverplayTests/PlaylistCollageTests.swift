import CoreGraphics
import ImageIO
import Foundation
import SwiftData
import Testing
@testable import Overplay

@Suite("Playlist collage")
@MainActor
struct PlaylistCollageTests {
    private func covers(_ count: Int) -> [PlaylistCollage.Cover] {
        (0..<count).map { .init(url: "cover-\($0)", latestDate: Date(timeIntervalSince1970: Double($0))) }
    }

    @Test func groupsUniqueArtworkByLatestDateInSelectedScope() {
        let playlist = PlaylistRecord(musicPlaylistID: "p", name: "Playlist")
        let tracks = (0..<3).map {
            TrackRecord(title: "Track \($0)", artistName: "Artist", artworkURLTemplate: $0 < 2 ? "shared" : "other")
        }
        let items = tracks.enumerated().map {
            PlaylistItemRecord(playlistID: playlist.id, trackID: $0.element.id, playthroughCount: $0.offset + 2, createdAt: Date(timeIntervalSince1970: Double($0.offset + 1)))
        }
        let retired = PlaylistItemRecord(playlistID: playlist.id, trackID: tracks[2].id, playthroughCount: 100, evictedAt: Date(timeIntervalSince1970: 10))
        let unrelated = PlaylistItemRecord(playlistID: UUID(), trackID: tracks[2].id, playthroughCount: 100)
        #expect(PlaylistCollage.covers(playlistID: playlist.id, items: items + [retired, unrelated], tracks: tracks) == [
            .init(url: "shared", latestDate: Date(timeIntervalSince1970: 2), plays: 5), .init(url: "other", latestDate: Date(timeIntervalSince1970: 3), plays: 4)
        ])
        #expect(PlaylistCollage.covers(playlistID: playlist.id, items: items + [retired, unrelated],
                                      tracks: tracks, scope: .retired) == [.init(url: "other", latestDate: Date(timeIntervalSince1970: 10), plays: 100)])
    }

    @Test func artworkRankingFollowsPlaylistRoleAndScope() throws {
        let container = try ModelContainer(for: PlaylistRecord.self, PlaylistItemRecord.self, TrackRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "otp", name: "Overplay", role: .oneTruePlaylist)
        context.insert(playlist)
        for index in 0..<80 {
            let track = TrackRecord(title: "Song", artistName: "Artist", artworkURLTemplate: "cover-\(index)")
            context.insert(track)
            context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: track.id,
                playthroughCount: 80 - index, createdAt: Date(timeIntervalSince1970: Double(index))))
        }
        let pile = try PlaylistCollageService.snapshot(for: playlist, in: context)
        #expect(pile.placements.last?.url == "cover-0")
        for (layout, count) in [(PlaylistCollageLayout.grid3, 9), (.grid8, 64)] {
            playlist.setCollageTemplate(layout: layout, stroke: .none, for: .active)
            let grid = try PlaylistCollageService.snapshot(for: playlist, in: context)
            #expect(Set(grid.placements.map(\.url)) == Set((0..<count).map { "cover-\($0)" }))
        }
        playlist.setCollageTemplate(layout: .pile, stroke: .none, for: .active)
        playlist.role = .triageBucket
        let triage = try PlaylistCollageService.snapshot(for: playlist, in: context, regenerate: true)
        #expect(triage.placements.last?.url == "cover-79")
        playlist.role = .oneTruePlaylist
        for item in try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context) {
            item.evictedAt = item.createdAt
        }
        let retired = try PlaylistCollageService.snapshot(for: playlist, in: context, scope: .retired)
        #expect(retired.placements.last?.url == "cover-79")
    }

    @Test(arguments: [PlaylistCollageLayout.grid3, .grid8])
    func gridsSelectTopCoversAndFillEveryCell(layout: PlaylistCollageLayout) {
        var random = SystemRandomNumberGenerator()
        let count = layout == .grid3 ? 9 : 64
        let collage = PlaylistCollage.make(covers: covers(80), layout: layout, stroke: .white, using: &random)
        #expect(collage.placements.count == count)
        #expect(Set(collage.placements.map(\.url)) == Set((80-count..<80).map { "cover-\($0)" }))
        let small = PlaylistCollage.make(covers: covers(2), layout: layout, stroke: .black, using: &random)
        #expect(small.placements.count == count)
        #expect(Set(small.placements.map(\.url)) == ["cover-0", "cover-1"])
        #expect(Set(collage.placements.map { "\($0.x),\($0.y)" }).count == count)
        #expect(collage.placements.allSatisfy { $0.rotation == 0 })
    }

    @Test func pileHasOrderedUniqueForegroundAndContainedRotatedCorners() throws {
        var random = SystemRandomNumberGenerator()
        let collage = PlaylistCollage.make(covers: covers(100), layout: .pile, stroke: .white, using: &random)
        #expect(collage.placements.allSatisfy { (0.30...0.60).contains($0.side) })
        let foreground = Array(collage.placements.dropFirst(25))
        #expect(foreground.map(\.url) == covers(100).map(\.url))
        for cover in foreground {
            #expect((0.30...0.60).contains(cover.side))
            #expect((-3...3).contains(cover.rotation))
            let angle = cover.rotation * .pi / 180
            let radius = cover.side * (abs(cos(angle)) + abs(sin(angle))) / 2
            #expect(cover.x - radius >= -0.000001 && cover.x + radius <= 1.000001)
            #expect(cover.y - radius >= -0.000001 && cover.y + radius <= 1.000001)
            #expect(abs(cover.strokeWidth / cover.side - 0.015) < 0.000001)
        }
        let top = try #require(foreground.last)
        #expect(top.side == 0.50 && top.x == 0.5 && top.y == 0.5)
    }

    @Test func underlayCoversCanvasEvenWithOneAlbum() {
        var random = SystemRandomNumberGenerator()
        let collage = PlaylistCollage.make(covers: covers(1), layout: .pile, stroke: .none, using: &random)
        let background = collage.placements.prefix(25)
        for x in 0...100 {
            for y in 0...100 {
                #expect(background.contains { cover in
                    let dx = Double(x) / 100 - cover.x
                    let dy = Double(y) / 100 - cover.y
                    let angle = cover.rotation * .pi / 180
                    return abs(dx * cos(angle) + dy * sin(angle)) <= cover.side / 2
                        && abs(-dx * sin(angle) + dy * cos(angle)) <= cover.side / 2
                })
            }
        }
    }

    @Test func refreshBoundaryAndSerialization() throws {
        var random = SystemRandomNumberGenerator()
        let date = Date(timeIntervalSince1970: 1234)
        let collage = PlaylistCollage.make(covers: covers(5), layout: .pile, stroke: .none, at: date, using: &random)
        #expect(!collage.needsRefresh(at: date.addingTimeInterval(86_399), layout: .pile, stroke: .none))
        #expect(collage.needsRefresh(at: date.addingTimeInterval(86_400), layout: .pile, stroke: .none))
        #expect(collage.needsRefresh(at: date, layout: .grid3, stroke: .none))
        #expect(collage.needsRefresh(at: date, layout: .pile, stroke: .black))
        #expect(try JSONDecoder().decode(PlaylistCollage.self, from: JSONEncoder().encode(collage)) == collage)
        var legacy = collage
        legacy.orderingVersion = 1
        #expect(legacy.needsRefresh(at: date, layout: .pile, stroke: .none))
        legacy.orderingVersion = nil
        #expect(legacy.needsRefresh(at: date, layout: .pile, stroke: .none))
        #expect(PlaylistCollage.make(covers: [], layout: .pile, stroke: .none, using: &random).placements.isEmpty)
    }

    @Test func sharedSnapshotStaysStableAndRegeneratesOnDemand() throws {
        let container = try ModelContainer(for: PlaylistRecord.self, PlaylistItemRecord.self, TrackRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "p", name: "Playlist")
        let track = TrackRecord(title: "Song", artistName: "Artist", artworkURLTemplate: "cover")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        context.insert(playlist); context.insert(track); context.insert(item)
        let date = Date(timeIntervalSince1970: 1234)
        let first = try PlaylistCollageService.snapshot(for: playlist, in: context, at: date)
        let carPlayContext = ModelContext(container)
        let carPlayPlaylist = try #require(try PlaylistRepository.playlist(id: playlist.id, in: carPlayContext))
        #expect(try PlaylistCollageService.snapshot(for: carPlayPlaylist, in: carPlayContext, at: date) == first)
        item.playthroughCount = 99
        let same = try PlaylistCollageService.snapshot(for: playlist, in: context, at: date.addingTimeInterval(1))
        #expect(same == first)
        let manual = try PlaylistCollageService.snapshot(for: playlist, in: context, regenerate: true, at: date)
        #expect(manual.id != first.id)
        let daily = try PlaylistCollageService.snapshot(for: playlist, in: context, at: date.addingTimeInterval(86_400))
        #expect(daily.id != manual.id)
        playlist.collageLayoutRawValue = "grid3"
        playlist.collageStrokeRawValue = "white"
        let changed = try PlaylistCollageService.snapshot(for: playlist, in: context, at: date.addingTimeInterval(86_401))
        #expect(changed.layout == .grid3 && changed.stroke == .white)
        #expect(changed.placements.count == 9)
        let otherConsumer = try PlaylistCollageService.snapshot(for: carPlayPlaylist, in: carPlayContext,
                                                               at: date.addingTimeInterval(86_401))
        #expect(otherConsumer == changed)
    }
    @Test func retiredSnapshotUsesRetiredTracksAndRefreshesIndependently() throws {
        let container = try ModelContainer(for: PlaylistRecord.self, PlaylistItemRecord.self, TrackRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "triage", name: "Triage", role: .triageBucket)
        let activeTrack = TrackRecord(title: "Active", artistName: "Artist", artworkURLTemplate: "active-cover")
        let retiredTrack = TrackRecord(title: "Retired", artistName: "Artist", artworkURLTemplate: "retired-cover")
        context.insert(playlist)
        context.insert(activeTrack)
        context.insert(retiredTrack)
        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: activeTrack.id, playthroughCount: 100))
        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: retiredTrack.id,
                                          playthroughCount: 1, evictedAt: .now))
        let date = Date.now
        let active = try PlaylistCollageService.snapshot(for: playlist, in: context, at: date)
        let retired = try PlaylistCollageService.snapshot(for: playlist, in: context, scope: .retired, at: date)
        #expect(Set(active.placements.map(\.url)) == ["active-cover"])
        #expect(Set(retired.placements.map(\.url)) == ["retired-cover"])
        #expect(active.id != retired.id)
        let refreshed = try PlaylistCollageService.snapshot(for: playlist, in: context, scope: .retired,
                                                           regenerate: true, at: date)
        #expect(refreshed.id != retired.id)
        #expect(try PlaylistCollageService.snapshot(for: playlist, in: context, at: date) == active)
        _ = try PlaylistCollageService.snapshot(for: playlist, in: context, regenerate: true, at: date)
        let carPlayContext = ModelContext(container)
        let otherPlaylist = try #require(try PlaylistRepository.playlist(id: playlist.id, in: carPlayContext))
        #expect(try PlaylistCollageService.snapshot(for: otherPlaylist, in: carPlayContext, scope: .retired,
                                                  at: date) == refreshed)

        playlist.setCollageTemplate(layout: .grid3, stroke: .none, for: .active)
        playlist.setCollageTemplate(layout: .grid3, stroke: .white, for: .retired)
        _ = try PlaylistCollageService.snapshot(for: playlist, in: context, at: date)
        let retiredGrid = try PlaylistCollageService.snapshot(for: playlist, in: context, scope: .retired, at: date)
        playlist.setCollageTemplate(layout: .grid8, stroke: .black, for: .active)
        let activeGrid = try PlaylistCollageService.snapshot(for: playlist, in: context, at: date)
        #expect(activeGrid.layout == .grid8 && activeGrid.stroke == .black)
        #expect(activeGrid.placements.count == 64)
        #expect(playlist.collageLayout(for: .retired) == .grid3)
        #expect(playlist.collageStroke(for: .retired) == .white)
        #expect(try PlaylistCollageService.snapshot(for: otherPlaylist, in: carPlayContext, scope: .retired,
                                                  at: date) == retiredGrid)

        playlist.setCollageTemplate(layout: .pile, stroke: .none, for: .retired)
        let retiredPile = try PlaylistCollageService.snapshot(for: playlist, in: context, scope: .retired, at: date)
        #expect(retiredPile.layout == .pile && retiredPile.stroke == .none)
        #expect(retiredPile.id != retiredGrid.id)
        #expect(try PlaylistCollageService.snapshot(for: otherPlaylist, in: carPlayContext, at: date) == activeGrid)
        let reopenedContext = ModelContext(container)
        let reopened = try #require(try PlaylistRepository.playlist(id: playlist.id, in: reopenedContext))
        #expect(reopened.collageLayout(for: .active) == .grid8)
        #expect(reopened.collageStroke(for: .active) == .black)
        #expect(reopened.collageLayout(for: .retired) == .pile)
        #expect(reopened.collageStroke(for: .retired) == .none)
    }

    @Test func renderedPNGIsReusedAcrossServiceInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(CGImageSourceCreateWithData(artworkTestData() as CFData, nil))
        let artwork = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var loads = 0
        let renderer = PlaylistCollageService(cacheDirectory: directory) { _, _, _ in
            loads += 1
            return artwork
        }
        var random = SystemRandomNumberGenerator()
        let collage = PlaylistCollage.make(covers: covers(1), layout: .grid3, stroke: .white, using: &random)
        let rendered = try #require(await renderer.image(for: collage, playlistID: "playlist"))
        #expect(rendered.width == 1024 && rendered.height == 1024)
        #expect(loads == 9)
        let folder = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let png = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        #expect(png.pathExtension == "png")
        #expect(try artworkDimensions(at: png) == [1024, 1024])
        let retired = PlaylistCollage.make(covers: covers(1), layout: .pile, stroke: .none, using: &random)
        #expect(await renderer.image(for: retired, playlistID: "playlist", scope: .retired) != nil)
        let reloaded = PlaylistCollageService(cacheDirectory: directory) { _, _, _ in
            Issue.record("Saved PNG should avoid fetching individual album covers")
            return nil
        }
        #expect(await reloaded.image(for: collage, playlistID: "playlist") != nil)
        #expect(await reloaded.image(for: retired, playlistID: "playlist", scope: .retired) != nil)
        // White border is drawn inside each tile, including the canvas boundary.
        let sample = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let corner = try #require(rendered.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
        sample.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(sample.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[0] > 245 && bytes[1] > 245 && bytes[2] > 245)
    }

    @Test(arguments: [PlaylistCollageLayout.pile, .grid3, .grid8],
          [PlaylistCollageStroke.none, .black, .white])
    func subtleShadowAppearsOnlyOutsideBorderlessPileCovers(
        layout: PlaylistCollageLayout, stroke: PlaylistCollageStroke
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        source.setFillColor(CGColor(gray: 1, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let whiteCover = try #require(source.makeImage())
        let renderer = PlaylistCollageService(cacheDirectory: directory) { _, _, _ in whiteCover }
        // A white underlay exposes the shadow just outside the centred cover.
        let collage = PlaylistCollage(id: UUID(), generatedAt: .now, layout: layout, stroke: stroke, placements: [
            .init(url: "background", x: 0.5, y: 0.5, side: 1, rotation: 0),
            .init(url: "foreground", x: 0.5, y: 0.5, side: 0.5, rotation: 0)
        ])
        let rendered = try #require(await renderer.image(for: collage, playlistID: "shadow-test"))
        func brightness(at x: Int) throws -> UInt8 {
            let pixel = try #require(rendered.cropping(to: CGRect(x: x, y: 512, width: 1, height: 1)))
            let sample = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            sample.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return try #require(sample.data).assumingMemoryBound(to: UInt8.self)[0]
        }
        let edge = try brightness(at: 254)
        if layout == .pile, stroke == .none {
            #expect(edge < 250 && edge > 190)
        } else {
            #expect(edge == 255)
        }
        #expect(try brightness(at: 230) == 255)
        #expect(try brightness(at: 512) == 255)
    }

    @Test func missingArtworkDoesNotFreezeAnIncompletePNG() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var loads = 0
        let renderer = PlaylistCollageService(cacheDirectory: directory) { _, _, _ in
            loads += 1
            return nil
        }
        var random = SystemRandomNumberGenerator()
        let collage = PlaylistCollage.make(covers: covers(1), layout: .grid3, stroke: .none, using: &random)
        #expect(await renderer.image(for: collage, playlistID: "missing") == nil)
        #expect(await renderer.image(for: collage, playlistID: "missing") == nil)
        #expect(loads == 18)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func tiedDatesCanChooseDifferentTopCoversAndGridSelections() {
        let tied = (0..<80).map { PlaylistCollage.Cover(url: "cover-\($0)", latestDate: Date(timeIntervalSince1970: 1)) }
        var random = CollageTestRandom(state: 17)
        var topCovers: Set<String> = []
        var selections: Set<Set<String>> = []
        for _ in 0..<10 {
            let pile = PlaylistCollage.make(covers: tied, layout: .pile, stroke: .none, using: &random)
            topCovers.insert(pile.placements.last!.url)
            let grid = PlaylistCollage.make(covers: tied, layout: .grid3, stroke: .none, using: &random)
            selections.insert(Set(grid.placements.map(\.url)))
        }
        #expect(topCovers.count > 1)
        #expect(selections.count > 1)
    }

}


private nonisolated struct CollageTestRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
