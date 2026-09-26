import Foundation
import ImageIO

nonisolated final class DecodedArtworkImage: NSObject, @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// UI hits are synchronous. Disk/network work and decoding are shared by asset,
/// never by playlist, so the same album has one decoded representation per size.
@MainActor
final class ArtworkImagePipeline {
    static let shared = ArtworkImagePipeline()
    private let memory = NSCache<NSString, DecodedArtworkImage>()
    private let disk: ArtworkCacheService
    private let decodeGate = ArtworkWorkGate(limit: 2)
    private var inFlight: [String: Task<DecodedArtworkImage?, Never>] = [:]

    init(disk: ArtworkCacheService = .shared, memoryBytes: Int = 24 * 1024 * 1024) {
        self.disk = disk
        memory.totalCostLimit = memoryBytes
    }

    func cachedImage(for url: String?, size: Int) -> CGImage? {
        guard let url else { return nil }
        return memory.object(forKey: ArtworkCacheService.cacheKey(sourceURL: url, pixelSize: size) as NSString)?.image
    }

    func image(for url: String?, size: Int, playlistID: String?, priority: TaskPriority = .userInitiated) async -> CGImage? {
        guard let url else { return nil }
        let size = ArtworkCacheService.sizeBucket(size)
        let key = ArtworkCacheService.cacheKey(sourceURL: url, pixelSize: size)
        if let image = memory.object(forKey: key as NSString) {
            MusicKitActivityLog.shared.record(.artworkMemoryHit, magnitude: Double(size))
            await disk.recordAccess(for: url, pixelSize: size, playlistID: playlistID)
            return image.image
        }
        let task: Task<DecodedArtworkImage?, Never>
        if let existing = inFlight[key] {
            MusicKitActivityLog.shared.record(.artworkRequestCoalesced, detail: "decode")
            task = existing
        } else {
            task = Task(priority: priority) {
                defer { inFlight[key] = nil }
                guard let file = await disk.artworkFileURL(for: url, pixelSize: size, playlistID: playlistID, priority: priority) else { return nil }
                let wait = PerformanceSpan(.artworkWorkWait)
                await decodeGate.acquire(priority: priority)
                wait.finish(detail: "display decode")
                let decoded = await Task.detached(priority: priority) {
                    let span = PerformanceSpan(.artworkDecode)
                    defer { span.finish(magnitude: Double(size), detail: "display") }
                    guard let source = CGImageSourceCreateWithURL(file as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: size
                          ] as CFDictionary) else { return nil as DecodedArtworkImage? }
                    return DecodedArtworkImage(image)
                }.value
                await decodeGate.release()
                if let decoded {
                    memory.setObject(decoded, forKey: key as NSString,
                        cost: decoded.image.bytesPerRow * decoded.image.height)
                }
                return decoded
            }
            inFlight[key] = task
        }
        let result = await task.value
        await disk.recordAccess(for: url, pixelSize: size, playlistID: playlistID)
        return result?.image
    }
}
