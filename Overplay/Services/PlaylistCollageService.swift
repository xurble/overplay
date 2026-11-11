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
    /// Renders held in `images` that lack covers which may yet load: each
    /// missing cover's URL and the size that render wanted it at.
    private var incompleteRenders: [UUID: [String: Int]] = [:]
    private var libraryObserver: NSObjectProtocol?
    private var maintenanceTask: Task<Void, Never>?

    /// The runtime owns composition maintenance. Views render snapshots;
    /// library changes can prepare newly linked or newly populated playlists
    /// even when no artwork view is currently being rebuilt.
    func maintainSnapshots(in container: ModelContainer) {
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
        maintenanceTask?.cancel()
        maintenanceTask = nil
        libraryObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] notification in
            guard LibraryPresentationChange(notification: notification).affectsArtwork else { return }
            let containerID = (notification.object as? ModelContext).map { ObjectIdentifier($0.container) }
            MainActor.assumeIsolated {
                guard containerID == ObjectIdentifier(container) else { return }
                self?.scheduleMaintenance(in: container)
            }
        }
        scheduleMaintenance(in: container)
    }

    private func scheduleMaintenance(in container: ModelContainer) {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            // Keep the task registered while saving: its own saves do not
            // recursively schedule another maintenance pass.
            defer { self.maintenanceTask = nil }
            try? Self.prepareSnapshots(in: container.mainContext)
        }
    }

    private let cacheDirectory: URL
    private let loadImage: @MainActor (String, Int, String) async -> CGImage?
    private let isCoverUnreachable: @MainActor (String) async -> Bool
    private let isCoverCached: @MainActor (String, Int) async -> Bool

    init(
        cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overplay/PlaylistCollages", isDirectory: true),
        loadImage: @escaping @MainActor (String, Int, String) async -> CGImage? = { url, size, playlist in
            await ArtworkImagePipeline.shared.image(for: url, size: size, playlistID: playlist, priority: .utility)
        },
        isCoverUnreachable: @escaping @MainActor (String) async -> Bool = { url in
            await ArtworkCacheService.shared.hasPermanentlyFailed(url)
        },
        isCoverCached: @escaping @MainActor (String, Int) async -> Bool = { url, size in
            await ArtworkCacheService.shared.cachedArtworkFileURL(for: url, pixelSize: size) != nil
        }
    ) {
        self.cacheDirectory = cacheDirectory
        self.loadImage = loadImage
        self.isCoverUnreachable = isCoverUnreachable
        self.isCoverCached = isCoverCached
        images.totalCostLimit = 24 * 1024 * 1024
    }

    /// Reading presentation state never writes to SwiftData.
    static func snapshot(for playlist: PlaylistRecord, scope: PlaylistPlaybackScope = .active) -> PlaylistCollage? {
        playlist.collageSnapshotData(for: scope).flatMap { try? JSONDecoder().decode(PlaylistCollage.self, from: $0) }
    }

    /// Called at library/surface lifecycle boundaries, independently of list
    /// rendering. Repeated saves converge on the same persisted compositions.
    static func prepareSnapshots(in context: ModelContext) throws {
        for playlist in try PlaylistRepository.activePlaylists(in: context) where playlist.role.isPlaybackContext {
            _ = try prepareSnapshot(for: playlist, in: context)
            if playlist.isTriageBucket { _ = try prepareSnapshot(for: playlist, in: context, scope: .retired) }
        }
    }

    static func prepareSnapshot(
        for playlist: PlaylistRecord, in context: ModelContext, scope: PlaylistPlaybackScope = .active,
        regenerate: Bool = false, at date: Date = .now
    ) throws -> PlaylistCollage {
        // Background callers may hold a context whose registered models are stale.
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
        let held = images.object(forKey: collage.id as NSUUID)
        if let held, await !canCompleteIncompleteRender(collage.id) { return held.image }
        if let task = inFlight[collage.id] { return await task.value }
        let task = Task { await render(collage, playlistID: playlistID, scope: scope) }
        inFlight[collage.id] = task
        let result = await task.value
        inFlight[collage.id] = nil
        return result ?? held?.image
    }

    /// An incomplete render stands for the session, so appearing again costs
    /// nothing. It is recomposed only once every cover it lacks has reached
    /// the disk cache some other way, such as a track row: that needs no
    /// request for those covers. A later launch, the daily refresh or
    /// Regenerate otherwise starts afresh.
    private func canCompleteIncompleteRender(_ id: UUID) async -> Bool {
        guard let missing = incompleteRenders[id] else { return false }
        for (url, size) in missing {
            guard await isCoverCached(url, size) else { return false }
        }
        return true
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
        guard var renderer = PlaylistCollageCanvas(collage: collage) else { return nil }
        let plan = await Self.renderPlan(of: collage, excluding: [])
        let first = await draw(plan, on: renderer, playlistID: playlistID)
        guard first.loadedAny else { return nil }
        var failed = first.failed
        if !failed.isEmpty {
            // A cover that failed no longer hides what lay under it. Draw once
            // more with that revealed, never asking again for a failed cover.
            let revealed = await Self.renderPlan(of: collage, excluding: Set(failed.keys))
            if !Set(revealed.coverSizes.keys).isSubset(of: plan.coverSizes.keys),
               let canvas = PlaylistCollageCanvas(collage: collage) {
                let second = await draw(revealed, on: canvas, playlistID: playlistID)
                failed.merge(second.failed) { earlier, _ in earlier }
                if second.loadedAny { renderer = canvas }
            }
        }
        // Do not freeze a transient network failure into the daily cache. A
        // cover that is permanently gone is a different matter: it will not
        // resolve on a re-render, so refusing to cache only buys a full
        // recomposition of every other cover each time the collage appears.
        var recoverable: [String: Int] = [:]
        for (url, size) in failed {
            if await !isCoverUnreachable(url) { recoverable[url] = size }
        }
        let result = await renderer.image()?.image
        if let result {
            images.setObject(DecodedArtworkImage(result), forKey: collage.id as NSUUID,
                             cost: result.bytesPerRow * result.height)
            incompleteRenders[collage.id] = recoverable.isEmpty ? nil : recoverable
        }
        if recoverable.isEmpty, let result {
            let image = DecodedArtworkImage(result)
            await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let bytes = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return }
                    CGImageDestinationAddImage(destination, image.image, nil)
                    guard CGImageDestinationFinalize(destination) else { return }
                    try (bytes as Data).write(to: file, options: .atomic)
                    // Keep just the latest complete image for this playlist. Compare
                    // names: listings can report the same file under another path
                    // (`/private/var` on iPhone), and URL inequality deleted it.
                    for old in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        where old.lastPathComponent != file.lastPathComponent && old.pathExtension == "png" {
                        try? FileManager.default.removeItem(at: old)
                    }
                } catch { /* Disposable cache; the saved arrangement can be rendered again. */ }
            }.value
        }
        return result
    }

    private static func renderPlan(of collage: PlaylistCollage, excluding unavailable: Set<String>) async -> PlaylistCollage.RenderPlan {
        await Task.detached(priority: .utility) { collage.renderPlan(excluding: unavailable) }.value
    }

    private func draw(
        _ plan: PlaylistCollage.RenderPlan, on renderer: PlaylistCollageCanvas, playlistID: String
    ) async -> (loadedAny: Bool, failed: [String: Int]) {
        var covers: [String: DecodedArtworkImage] = [:]
        var failed: [String: Int] = [:]
        var loadedAny = false
        // Bound retained decoded images as well as concurrent requests. A large
        // pile must not hold every album cover in memory at once.
        for start in stride(from: 0, to: plan.placements.count, by: 16) {
            let placements = Array(plan.placements[start..<min(start + 16, plan.placements.count)])
            let urls = Set(placements.map(\.url))
            covers = covers.filter { urls.contains($0.key) }
            let missing = urls.filter { covers[$0] == nil && failed[$0] == nil }.sorted()
            let loaded = await loadCovers(missing, sizes: plan.coverSizes, playlistID: playlistID)
            covers.merge(loaded) { _, new in new }
            for url in missing where loaded[url] == nil { failed[url] = plan.coverSizes[url] ?? 512 }
            loadedAny = loadedAny || !covers.isEmpty
            await renderer.draw(placements, covers: covers)
        }
        return (loadedAny, failed)
    }

    private func loadCover(_ url: String, size: Int, playlistID: String) async -> DecodedArtworkImage? {
        await loadImage(url, size, playlistID).map(DecodedArtworkImage.init)
    }

    private func loadCovers(_ urls: [String], sizes: [String: Int], playlistID: String) async -> [String: DecodedArtworkImage] {
        return await withTaskGroup(of: (String, DecodedArtworkImage?).self) { group in
            var next = min(4, urls.count)
            var loaded: [String: DecodedArtworkImage] = [:]
            for url in urls.prefix(4) {
                group.addTask {
                    (url, await self.loadCover(url, size: sizes[url] ?? 512, playlistID: playlistID))
                }
            }
            for await (url, image) in group {
                if let image { loaded[url] = image }
                if next < urls.count {
                    let url = urls[next]
                    next += 1
                    group.addTask {
                        (url, await self.loadCover(url, size: sizes[url] ?? 512, playlistID: playlistID))
                    }
                }
            }
            return loaded
        }
    }
}

/// Own the CGContext on a separate actor so composition never blocks SwiftUI.
private actor PlaylistCollageCanvas {
    private let canvas: CGContext
    private let collage: PlaylistCollage
    private let scale = 1024.0

    init?(collage: PlaylistCollage) {
        guard let canvas = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        self.canvas = canvas
        self.collage = collage
        canvas.interpolationQuality = .high
        canvas.setFillColor(CGColor(gray: 0.12, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }

    func draw(_ placements: [PlaylistCollage.Placement], covers: [String: DecodedArtworkImage]) {
        for placement in placements {
            guard let image = covers[placement.url]?.image else { continue }
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
    }

    func image() -> DecodedArtworkImage? {
        canvas.makeImage().map(DecodedArtworkImage.init)
    }
}
