import SwiftUI

struct ArtworkView: View {
    var urlString: String?
    var pixelSize: Int = 512
    var playlistID: String?
    var cornerRadius: CGFloat = 22

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
            .onDisappear {
                image = nil
                loadedCacheIdentity = nil
            }
            .task(id: cacheIdentity) {
                await loadArtwork()
            }
    }

    private var artworkContent: some View {
        Group {
            if let image = displayedImage {
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
        "\(urlString ?? "")|\(ArtworkCacheService.sizeBucket(pixelSize))"
    }

    private var displayedImage: CGImage? {
        if loadedCacheIdentity == cacheIdentity, let image { return image }
        return ArtworkImagePipeline.shared.cachedImage(for: urlString, size: pixelSize)
            ?? ArtworkImagePipeline.shared.cachedImage(for: urlString, size: 128)
    }

    private func loadArtwork() async {
        let identity = cacheIdentity
        if loadedCacheIdentity != identity {
            image = nil
            loadedCacheIdentity = identity
        }
        let pipeline = ArtworkImagePipeline.shared
        if let ready = pipeline.cachedImage(for: urlString, size: pixelSize) {
            image = ready
            loadedCacheIdentity = identity
        } else if ArtworkCacheService.sizeBucket(pixelSize) == 512 {
            // Keep a useful thumbnail visible throughout the large-image request.
            let thumbnail = await pipeline.image(for: urlString, size: 128, playlistID: playlistID)
            guard !Task.isCancelled, identity == cacheIdentity else { return }
            image = thumbnail
            loadedCacheIdentity = identity
        }
        let result = await pipeline.image(for: urlString, size: pixelSize, playlistID: playlistID)
        guard !Task.isCancelled, identity == cacheIdentity else { return }
        if let result { image = result }
        loadedCacheIdentity = identity
    }

}

#Preview {
    ArtworkView()
        .frame(width: 220, height: 220)
        .padding()
}
