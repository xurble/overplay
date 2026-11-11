import CoreGraphics
import Testing
@testable import Overplay

@Suite("Player backdrop style")
struct PlayerBackdropStyleTests {
    private let theme = AlbumArtworkTheme(
        backgroundRGB: .init(0.30, 0.10, 0.12),
        trackTitleRGB: .init(0.96, 0.80, 0.40),
        artistNameRGB: .init(0.90, 0.80, 0.70),
        albumNameRGB: .init(0.80, 0.70, 0.60),
        isFallback: false,
        source: .palette
    )

    @Test("cover present and theme pending: blurred art under a neutral wash")
    func pendingThemeWithArtShowsNeutralArt() {
        #expect(PlayerBackdropStyle.style(for: .fallback, hasArtwork: true) == .neutralArt)
    }

    @Test("no art and no theme: the plain background")
    func noArtShowsPlainBackground() {
        #expect(PlayerBackdropStyle.style(for: .fallback, hasArtwork: false) == .plain)
    }

    @Test("a theme: blurred art under the theme colour")
    func themeShowsThemedArt() {
        #expect(PlayerBackdropStyle.style(for: theme, hasArtwork: true) == .themedArt(theme.backgroundRGB))
    }

    /// While the theme is pending, text keeps the system label colours, which
    /// do not adapt to the art, so the neutral wash must hold them readable
    /// over white art in dark mode and black art in light mode.
    @Test("system text colours read over the neutral wash on any art")
    func neutralWashKeepsSystemTextLegible() {
        let white = AlbumArtworkRGBColor(1, 1, 1)
        let black = AlbumArtworkRGBColor(0, 0, 0)
        // Dark mode: black system background over white art.
        let dark = white.mixed(with: black, amount: CGFloat(PlayerBackdropStyle.neutralWash(isDark: true)))
        // Light mode: white system background over black art.
        let light = black.mixed(with: white, amount: CGFloat(PlayerBackdropStyle.neutralWash(isDark: false)))
        // Secondary label: the system's secondary label colour, 60% opaque.
        let darkSecondary = dark.mixed(with: AlbumArtworkRGBColor(0.92, 0.92, 0.96), amount: 0.6)
        let lightSecondary = light.mixed(with: AlbumArtworkRGBColor(0.24, 0.24, 0.26), amount: 0.6)

        #expect(white.contrastRatio(against: dark) >= 4.5)
        #expect(black.contrastRatio(against: light) >= 4.5)
        #expect(darkSecondary.contrastRatio(against: dark) >= 3.0)
        #expect(lightSecondary.contrastRatio(against: light) >= 3.0)
    }
}
