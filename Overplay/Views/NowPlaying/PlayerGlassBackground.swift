import CoreMotion
import SwiftUI

/// The full player's background, for its glass controls to refract: the
/// album art, lightly blurred under a theme-colour wash, drifting with the
/// phone's tilt so the refracted image moves with the glass highlight.
struct PlayerGlassArtwork: Equatable {
    var urlString: String
    var playlistID: String?
}

extension EnvironmentValues {
    @Entry var playerGlassArtwork: PlayerGlassArtwork? = nil
    @Entry var playerGlassBackdrop: PlayerGlassBackdrop? = nil
}

/// What the art background looks like under any point of the player: the
/// art averaged into a grid (close to what the blur leaves), under the theme
/// wash. Lets text pick a colour that reads where it actually sits.
@MainActor
@Observable
final class PlayerGlassBackdrop {
    static let coordinateSpace = "playerGlassSheet"
    private nonisolated static let gridSize = 24

    private(set) var grid: [AlbumArtworkRGBColor] = []
    /// Where the art is drawn, in the player's coordinate space.
    var artFrame: CGRect = .zero
    var tint = AlbumArtworkRGBColor(0, 0, 0)
    @ObservationIgnored private var loadedURL: String?

    func load(_ artwork: PlayerGlassArtwork?) async {
        guard artwork?.urlString != loadedURL else { return }
        loadedURL = artwork?.urlString
        guard let artwork,
              let image = await ArtworkImagePipeline.shared.image(for: artwork.urlString, size: 128, playlistID: artwork.playlistID),
              loadedURL == artwork.urlString else {
            grid = []
            return
        }
        grid = Self.averages(of: image)
    }

    /// The colour under a rectangle in the player's coordinate space.
    func colour(under rect: CGRect) -> AlbumArtworkRGBColor? {
        let n = Self.gridSize
        guard grid.count == n * n, artFrame.height > 0, !rect.isEmpty else { return nil }
        let side: CGFloat = artFrame.height
        let originX: CGFloat = artFrame.minX
        let originY: CGFloat = artFrame.minY
        func cell(_ value: CGFloat, _ origin: CGFloat) -> Int {
            let position: CGFloat = (value - origin) / side * CGFloat(n)
            return min(max(Int(position), 0), n - 1)
        }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var count: CGFloat = 0
        for row in cell(rect.minY, originY)...cell(rect.maxY, originY) {
            for column in cell(rect.minX, originX)...cell(rect.maxX, originX) {
                let colour = grid[row * n + column]
                r += colour.r
                g += colour.g
                b += colour.b
                count += 1
            }
        }
        let average = AlbumArtworkRGBColor(r / count, g / count, b / count)
        return average.mixed(with: tint, amount: CGFloat(PlayerGlassArtBackground.wash))
    }

    private nonisolated static func averages(of image: CGImage) -> [AlbumArtworkRGBColor] {
        let n = gridSize
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return [] }
        var colours: [AlbumArtworkRGBColor] = []
        colours.reserveCapacity(n * n)
        for index in 0..<(n * n) {
            let base = index * 4
            let red = CGFloat(pixels[base]) / 255
            let green = CGFloat(pixels[base + 1]) / 255
            let blue = CGFloat(pixels[base + 2]) / 255
            colours.append(AlbumArtworkRGBColor(red, green, blue))
        }
        return colours
    }
}

/// A glass layer between the art and some text.
struct PlayerGlassTint: Equatable {
    var colour: AlbumArtworkRGBColor
    var opacity: CGFloat
}

/// Uses `preferred` where it reads against what is underneath, otherwise the
/// nearest colour toward white or black that does. Outside the full player,
/// or with no theme, it is `fallback`.
struct PlayerLegibleForeground: ViewModifier {
    var preferred: AlbumArtworkRGBColor?
    var fallback: Color
    var glass: PlayerGlassTint?
    var isActive: Bool

    @Environment(\.playerGlassBackdrop) private var backdrop
    @State private var frame: CGRect = .zero
    private static let minimumContrast: CGFloat = 4.5

    func body(content: Content) -> some View {
        content
            .foregroundStyle(colour)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(PlayerGlassBackdrop.coordinateSpace))
            } action: { frame = $0 }
    }

    private var colour: Color {
        guard isActive, let preferred, let backdrop, var under = backdrop.colour(under: frame) else { return fallback }
        if let glass { under = under.mixed(with: glass.colour, amount: glass.opacity) }
        return Self.legible(preferred, on: under).color
    }

    static func legible(_ preferred: AlbumArtworkRGBColor, on background: AlbumArtworkRGBColor) -> AlbumArtworkRGBColor {
        if preferred.contrastRatio(against: background) >= minimumContrast { return preferred }
        let white = AlbumArtworkRGBColor(1, 1, 1), black = AlbumArtworkRGBColor(0, 0, 0)
        let extremes = [white, black].sorted { $0.contrastRatio(against: background) > $1.contrastRatio(against: background) }
        for extreme in extremes {
            for step in 1...10 {
                let candidate = preferred.mixed(with: extreme, amount: CGFloat(step) / 10)
                if candidate.contrastRatio(against: background) >= minimumContrast { return candidate }
            }
        }
        return extremes[0]
    }
}

extension View {
    func playerLegibleForeground(
        _ preferred: AlbumArtworkRGBColor?,
        fallback: Color,
        glass: PlayerGlassTint? = nil,
        isActive: Bool = true
    ) -> some View {
        modifier(PlayerLegibleForeground(preferred: preferred, fallback: fallback, glass: glass, isActive: isActive))
    }
}

/// Device tilt relative to how the phone was held when the player opened,
/// each axis normalised to -1...1. One motion source for every control.
@MainActor
@Observable
final class PlayerGlassMotion {
    static let shared = PlayerGlassMotion()

    private(set) var tilt: CGSize = .zero

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var reference: CMAttitude?
    private static let fullTilt = 0.45

    func start() {
        users += 1
        guard users == 1, manager.isDeviceMotionAvailable else { return }
        reference = nil
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let attitude = motion?.attitude else { return }
            MainActor.assumeIsolated { self?.update(attitude) }
        }
    }

    func stop() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        manager.stopDeviceMotionUpdates()
        tilt = .zero
    }

    private func update(_ attitude: CMAttitude) {
        guard let reference else {
            reference = attitude.copy() as? CMAttitude
            return
        }
        attitude.multiply(byInverseOf: reference)
        func normalised(_ angle: Double) -> CGFloat {
            CGFloat(min(max(angle / Self.fullTilt, -1), 1))
        }
        tilt = CGSize(width: normalised(attitude.roll), height: normalised(attitude.pitch))
    }
}

/// Fades a view holding glass. Always the same modifier, so the view keeps
/// its identity (a conditional rebuilt the pane near full extension).
struct PlayerGlassFade: ViewModifier {
    var opacity: Double

    func body(content: Content) -> some View {
        content.opacity(opacity)
    }
}

/// The full player background: the album art filling the height, heavily
/// blurred, drifting with the phone's tilt, under a wash of the theme
/// background colour (as CarPlay darkens its art, but in the theme colour).
struct PlayerGlassArtBackground: View {
    var tint: Color

    @Environment(\.playerGlassArtwork) private var artwork
    @Environment(\.playerGlassBackdrop) private var backdrop
    private let motion = PlayerGlassMotion.shared
    static let oversize: CGFloat = 1.25
    private static let blur: CGFloat = 8
    private static let parallax: CGFloat = 0.22
    static let wash: Double = 0.5

    /// The tallest the player has been: the art keeps the full-size player's
    /// size and position, and a shrinking sheet crops it rather than
    /// shrinking it, so its edges never show.
    @State private var fullHeight: CGFloat = 0

    /// The art square for a player of this size.
    static func artFrame(for size: CGSize, fullHeight: CGFloat) -> CGRect {
        let reference = max(fullHeight, size.height)
        let side = max(reference, size.width) * oversize
        return CGRect(x: (size.width - side) / 2, y: (reference - side) / 2, width: side, height: side)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = Self.artFrame(for: size, fullHeight: fullHeight)
            let margin = (frame.height - max(fullHeight, size.height)) / 2
            ZStack(alignment: .topLeading) {
                tint
                if let artwork {
                    NowPlayingArtworkView(urlString: artwork.urlString, playlistID: artwork.playlistID, cornerRadius: 0)
                        .frame(width: frame.width, height: frame.height)
                        .blur(radius: Self.blur)
                        .offset(
                            x: frame.minX + motion.tilt.width * margin * Self.parallax,
                            y: frame.minY + motion.tilt.height * margin * Self.parallax
                        )
                }
                tint.opacity(Self.wash)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            fullHeight = max(fullHeight, size.height)
            backdrop?.artFrame = Self.artFrame(for: size, fullHeight: fullHeight)
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }
}

#Preview {
    PlayerGlassArtBackground(tint: .indigo)
}
