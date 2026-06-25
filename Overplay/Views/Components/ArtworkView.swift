import ImageIO
import SwiftUI

private struct DecodedArtworkImage: @unchecked Sendable {
    var image: CGImage

    nonisolated init(image: CGImage) {
        self.image = image
    }
}

private actor DecodedArtworkImageCache {
    static let shared = DecodedArtworkImageCache()

    private let maxImageCount = 300
    private var images: [String: DecodedArtworkImage] = [:]
    private var keysInAccessOrder: [String] = []

    func image(for key: String) -> DecodedArtworkImage? {
        guard let image = images[key] else { return nil }
        markAccessed(key)
        return image
    }

    func store(_ image: DecodedArtworkImage, for key: String) {
        images[key] = image
        markAccessed(key)

        while keysInAccessOrder.count > maxImageCount {
            let expiredKey = keysInAccessOrder.removeFirst()
            images[expiredKey] = nil
        }
    }

    private func markAccessed(_ key: String) {
        keysInAccessOrder.removeAll { $0 == key }
        keysInAccessOrder.append(key)
    }
}

nonisolated private func decodedArtworkImage(contentsOf url: URL, maxPixelSize: Int) -> DecodedArtworkImage? {
    let sourceOptions: [CFString: Any] = [
        kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
        return nil
    }

    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        return nil
    }

    return DecodedArtworkImage(image: image)
}

struct ArtworkView: View {
    var urlString: String?
    var pixelSize: Int = 512
    var playlistID: String?
    var cornerRadius: CGFloat = 22
    var loadsImmediately = true

    @State private var image: CGImage?
    @State private var loadedCacheIdentity: String?

    var body: some View {
        artworkContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .task(id: loadIdentity) {
                await loadArtwork()
            }
    }

    private var artworkContent: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo, .teal, .pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    private var cacheIdentity: String {
        "\(urlString ?? "")|\(pixelSize)|\(playlistID ?? "")"
    }

    private var loadIdentity: String {
        "\(cacheIdentity)|\(loadsImmediately)"
    }

    private func loadArtwork() async {
        guard loadsImmediately else { return }

        let cacheIdentity = cacheIdentity
        if let cachedImage = await DecodedArtworkImageCache.shared.image(for: cacheIdentity) {
            await MainActor.run {
                image = cachedImage.image
                loadedCacheIdentity = cacheIdentity
            }
            return
        }

        await MainActor.run {
            if loadedCacheIdentity != cacheIdentity {
                image = nil
                loadedCacheIdentity = cacheIdentity
            }
        }
        guard let urlString else { return }

        let fileURL: URL?
        if let cachedFileURL = await ArtworkCacheService.shared.cachedArtworkFileURL(
            for: urlString,
            pixelSize: pixelSize
        ) {
            fileURL = cachedFileURL
        } else {
            fileURL = await ArtworkCacheService.shared.artworkFileURL(
                for: urlString,
                pixelSize: pixelSize,
                playlistID: playlistID
            )
        }
        guard !Task.isCancelled, let fileURL else { return }

        let pixelSize = pixelSize
        let loadedImage = await Task.detached(priority: .utility) {
            decodedArtworkImage(contentsOf: fileURL, maxPixelSize: pixelSize)
        }.value
        guard !Task.isCancelled, let loadedImage else { return }

        await DecodedArtworkImageCache.shared.store(loadedImage, for: cacheIdentity)
        await MainActor.run {
            image = loadedImage.image
            loadedCacheIdentity = cacheIdentity
        }
    }
}

#Preview {
    ArtworkView()
        .frame(width: 220, height: 220)
        .padding()
}
