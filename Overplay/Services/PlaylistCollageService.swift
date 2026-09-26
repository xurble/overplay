import CryptoKit
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// One persisted composition and one rendered image shared by app and CarPlay.
@MainActor
final class PlaylistCollageService {
    static let shared = PlaylistCollageService()
    private let images = NSCache<NSUUID, DecodedArtworkImage>()
    private var inFlight: [UUID: Task<CGImage?, Never>] = [:]

    private let cacheDirectory: URL
    private let loadImage: @MainActor (String, Int, String) async -> CGImage?

    init(
        cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overplay/PlaylistCollages", isDirectory: true),
        loadImage: @escaping @MainActor (String, Int, String) async -> CGImage? = { url, size, playlist in
            await ArtworkImagePipeline.shared.image(for: url, size: size, playlistID: playlist, priority: .utility)
        }
    ) {
        self.cacheDirectory = cacheDirectory
        self.loadImage = loadImage
        images.totalCostLimit = 24 * 1024 * 1024
    }

    static func snapshot(
        for playlist: PlaylistRecord, in context: ModelContext, scope: PlaylistPlaybackScope = .active,
        regenerate: Bool = false, at date: Date = .now
    ) throws -> PlaylistCollage {
        // CarPlay holds a separate context whose registered models can be stale.
        // Resolve every surface through the same main-context record before
        // deciding whether to reuse or regenerate; never overwrite newer settings.
        let sharedContext = context.container.mainContext
        let playlist = try PlaylistRepository.playlist(id: playlist.id, in: sharedContext) ?? playlist
        let context = sharedContext
        let layout = playlist.collageLayout(for: scope)
        let stroke = playlist.collageStroke(for: scope)
        let existing = playlist.collageSnapshotData(for: scope).flatMap { try? JSONDecoder().decode(PlaylistCollage.self, from: $0) }
        if !regenerate, let existing, !existing.needsRefresh(at: date, layout: layout, stroke: stroke),
           !existing.placements.isEmpty {
            return existing
        }
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let covers = PlaylistCollage.covers(playlistID: playlist.id, items: items, tracks: tracks, scope: scope)
        // Empty playlists can acquire artwork immediately after their first sync.
        if !regenerate, covers.isEmpty, let existing,
           !existing.needsRefresh(at: date, layout: layout, stroke: stroke) { return existing }
        var random = SystemRandomNumberGenerator()
        let snapshot = PlaylistCollage.make(covers: covers, layout: layout, stroke: stroke,
            rankByPlayCount: playlist.role == .oneTruePlaylist && scope == .active, at: date, using: &random)
        let previous = playlist.collageSnapshotData(for: scope)
        playlist.setCollageSnapshotData(try JSONEncoder().encode(snapshot), for: scope)
        do { try context.save() }
        catch { playlist.setCollageSnapshotData(previous, for: scope); throw error }
        return snapshot
    }

    func image(for collage: PlaylistCollage, playlistID: String, scope: PlaylistPlaybackScope = .active) async -> CGImage? {
        if let image = images.object(forKey: collage.id as NSUUID) { return image.image }
        if let task = inFlight[collage.id] { return await task.value }
        let task = Task { await render(collage, playlistID: playlistID, scope: scope) }
        inFlight[collage.id] = task
        let result = await task.value
        inFlight[collage.id] = nil
        return result
    }

    private func render(_ collage: PlaylistCollage, playlistID: String, scope: PlaylistPlaybackScope) async -> CGImage? {
        guard !collage.placements.isEmpty else { return nil }
        let cacheIdentity = scope == .active ? playlistID : "\(playlistID)#retired"
        let playlistKey = SHA256.hash(data: Data(cacheIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = cacheDirectory.appendingPathComponent(playlistKey, isDirectory: true)
        let file = directory.appendingPathComponent("\(collage.id).png")
        let cached = await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: file.path),
                  let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil as DecodedArtworkImage? }
            return DecodedArtworkImage(image)
        }.value
        if let cached {
            images.setObject(cached, forKey: collage.id as NSUUID, cost: cached.image.bytesPerRow * cached.image.height)
            return cached.image
        }
        let edge = 1024
        guard let canvas = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        canvas.interpolationQuality = .high
        let scale = Double(edge)
        canvas.setFillColor(CGColor(gray: 0.12, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
        var complete = true
        var loadedAny = false
        for placement in collage.placements {
            let image = await loadImage(placement.url, collage.layout == .grid8 ? 128 : 512, playlistID)
            guard let image else { complete = false; continue }
            loadedAny = true
            canvas.saveGState()
            canvas.translateBy(x: placement.x * scale, y: (1 - placement.y) * scale)
            canvas.rotate(by: -placement.rotation * .pi / 180)
            let side = placement.side * scale
            let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
            if collage.layout == .pile, collage.stroke == .none {
                // Draw the shadow before clipping the artwork so it can extend
                // beyond the cover. Keep its softness and offset proportional.
                canvas.saveGState()
                canvas.setShadow(offset: CGSize(width: 0, height: -side * 0.006),
                                 blur: side * 0.012, color: CGColor(gray: 0, alpha: 0.24))
                canvas.setFillColor(CGColor(gray: 0, alpha: 1))
                canvas.fill(rect)
                canvas.restoreGState()
            }
            canvas.saveGState()
            canvas.clip(to: rect)
            // Aspect-fill without distorting non-square artwork.
            let factor = max(side / Double(image.width), side / Double(image.height))
            let width = Double(image.width) * factor
            let height = Double(image.height) * factor
            canvas.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            canvas.restoreGState()
            if collage.stroke != .none {
                let line = placement.strokeWidth * scale
                canvas.setStrokeColor(CGColor(gray: collage.stroke == .white ? 1 : 0, alpha: 1))
                canvas.setLineWidth(line)
                canvas.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
            }
            canvas.restoreGState()
        }
        guard loadedAny else { return nil }
        let result = canvas.makeImage()
        // Do not freeze a transient network failure into the daily cache.
        if complete, let result {
            images.setObject(DecodedArtworkImage(result), forKey: collage.id as NSUUID,
                             cost: result.bytesPerRow * result.height)
            let image = DecodedArtworkImage(result)
            await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let bytes = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return }
                    CGImageDestinationAddImage(destination, image.image, nil)
                    guard CGImageDestinationFinalize(destination) else { return }
                    try (bytes as Data).write(to: file, options: .atomic)
                    // Keep just the latest complete image for this playlist.
                    for old in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        where old != file && old.pathExtension == "png" {
                        try? FileManager.default.removeItem(at: old)
                    }
                } catch { /* Disposable cache; the saved arrangement can be rendered again. */ }
            }.value
        }
        return result
    }
}
