import ImageIO
import SwiftUI

/// The cover in the Mac's full-screen player: as large as `maxSide` allows,
/// but never drawn past the cover's own resolution. The artwork cache keeps
/// 512 pixels at most, so this loads the current cover at the size it is
/// shown; Apple's artwork server never returns more than the original, so
/// the image's own size is the cap. The cached cover stands in until it
/// arrives, and caps the size if it never does.
struct MacFullScreenArtworkView: View {
    var urlString: String?
    var playlistID: String?
    var maxSide: CGFloat

    @Environment(\.displayScale) private var displayScale
    /// The last large cover loaded, possibly the last song's while this
    /// one's loads: its size holds the art steady across a skip.
    @State private var large: LargeCover?

    private struct LargeCover {
        var urlString: String
        /// Nil when the large cover could not be loaded.
        var image: CGImage?
    }

    static let cornerRadius: CGFloat = 18

    var body: some View {
        let side = Self.side(maxSide: maxSide, nativePixels: nativePixels, scale: displayScale)
        // The cached cover is always there, under the large one: it keeps the
        // last song's cover until this one's arrives. Made afresh at each
        // skip, it showed its purple placeholder in between.
        NowPlayingArtworkView(urlString: urlString, playlistID: playlistID, cornerRadius: Self.cornerRadius)
            .overlay {
                if let large, large.urlString == urlString, let image = large.image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        }
                }
            }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.28), radius: 22, y: 16)
        .accessibilityHidden(true)
        .task(id: "\(urlString ?? "")|\(Self.requestPixels(maxSide: maxSide, scale: displayScale))") {
            await load()
        }
    }

    /// The pixel width of the best cover there is for this song: the large
    /// one; the cache's 512 if it failed; while it loads, the last large
    /// cover's, so a skip does not change the size.
    private var nativePixels: Int? {
        guard let large else { return nil }
        if large.urlString == urlString { return large.image?.width ?? 512 }
        return large.image?.width
    }

    /// As large as allowed, and no larger than the cover's own pixels.
    static func side(maxSide: CGFloat, nativePixels: Int?, scale: CGFloat) -> CGFloat {
        let fitted = max(0, maxSide.rounded(.down))
        guard let nativePixels, scale > 0 else { return fitted }
        return min(fitted, (CGFloat(nativePixels) / scale).rounded(.down))
    }

    /// The pixels to ask for: the shown size, in steps of 256 so a small
    /// change in the space does not load the cover again.
    static func requestPixels(maxSide: CGFloat, scale: CGFloat) -> Int {
        let pixels = max(1, Int((maxSide * scale).rounded(.up)))
        return min(4096, (pixels + 255) / 256 * 256)
    }

    static func requestURL(template: String, pixels: Int) -> URL? {
        guard let template = PortableArtworkReference.validated(template) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{w}", with: "\(pixels)")
            .replacingOccurrences(of: "{h}", with: "\(pixels)"))
    }

    private func load() async {
        guard let urlString, maxSide > 0,
              let url = Self.requestURL(template: urlString, pixels: Self.requestPixels(maxSide: maxSide, scale: displayScale))
        else { return }
        let image: CGImage?
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            image = await Task.detached(priority: .userInitiated) {
                CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }.value
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
        }
        guard !Task.isCancelled, urlString == self.urlString else { return }
        large = LargeCover(urlString: urlString, image: image)
    }
}

#Preview {
    MacFullScreenArtworkView(urlString: nil, maxSide: 400)
        .padding(40)
}
