import SwiftUI

#if os(macOS)
import AppKit

private typealias OverplayPlatformImage = NSImage

private extension Image {
    init(overplayPlatformImage image: OverplayPlatformImage) {
        self.init(nsImage: image)
    }
}

private func platformImage(contentsOf url: URL) -> OverplayPlatformImage? {
    OverplayPlatformImage(contentsOf: url)
}
#else
import UIKit

private typealias OverplayPlatformImage = UIImage

private extension Image {
    init(overplayPlatformImage image: OverplayPlatformImage) {
        self.init(uiImage: image)
    }
}

private func platformImage(contentsOf url: URL) -> OverplayPlatformImage? {
    OverplayPlatformImage(contentsOfFile: url.path)
}
#endif

struct ArtworkView: View {
    var urlString: String?
    var pixelSize: Int = 512
    var playlistID: String?
    var cornerRadius: CGFloat = 22

    @State private var image: OverplayPlatformImage?

    var body: some View {
        artworkContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .task(id: cacheIdentity) {
                await loadArtwork()
            }
    }

    private var artworkContent: some View {
        Group {
            if let image {
                Image(overplayPlatformImage: image)
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

    @MainActor
    private func loadArtwork() async {
        image = nil
        guard let urlString else { return }

        let fileURL = await ArtworkCacheService.shared.artworkFileURL(
            for: urlString,
            pixelSize: pixelSize,
            playlistID: playlistID
        )
        guard !Task.isCancelled, let fileURL else { return }

        guard let baseImage = platformImage(contentsOf: fileURL) else { return }
        image = baseImage
    }
}

#Preview {
    ArtworkView()
        .frame(width: 220, height: 220)
        .padding()
}
