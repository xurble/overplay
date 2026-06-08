import CoreGraphics
import Testing
@testable import Overplay

@Suite("Album artwork theme")
struct AlbumArtworkThemeTests {
    @Test("colourful artwork uses a darkened dominant background and readable artwork text")
    func colorfulArtworkUsesReadableArtworkColours() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.94, 0.08, 0.04, 120),
            (0.98, 0.82, 0.12, 70),
            (0.06, 0.48, 0.92, 50),
            (0.10, 0.78, 0.34, 40)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.r > theme.backgroundRGB.g)
        #expect(theme.backgroundRGB.relativeLuminance <= 0.30)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
        #expect(theme.artistNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
        #expect(theme.albumNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
    }

    @Test("mostly black artwork keeps a dark background and light readable text")
    func mostlyBlackArtwork() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.01, 0.01, 0.01, 160),
            (0.10, 0.10, 0.11, 40),
            (0.18, 0.18, 0.19, 20)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.relativeLuminance < 0.08)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("mostly white artwork does not create a blinding full-screen background")
    func mostlyWhiteArtwork() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.98, 0.98, 0.96, 180),
            (0.84, 0.84, 0.82, 40),
            (0.66, 0.66, 0.64, 15)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.relativeLuminance > 0.35)
        #expect(theme.backgroundRGB.relativeLuminance < 0.70)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("bright colourful artwork keeps a visible light-derived tint")
    func brightColourfulArtworkKeepsVisibleTint() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.96, 0.82, 0.16, 160),
            (0.06, 0.08, 0.12, 48),
            (0.90, 0.40, 0.10, 32)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.relativeLuminance > 0.24)
        #expect(theme.backgroundRGB.r > 0.35)
        #expect(theme.backgroundRGB.g > 0.30)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("pastel artwork does not collapse into a near-black background")
    func pastelArtworkDoesNotCollapseToNearBlack() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.94, 0.62, 0.72, 120),
            (0.62, 0.88, 0.78, 80),
            (0.72, 0.72, 0.92, 60)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.relativeLuminance > 0.24)
        #expect(theme.backgroundRGB.saturation > 0.18)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("black and white artwork stays neutral instead of inventing colour")
    func blackAndWhiteArtworkStaysNeutral() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.04, 0.04, 0.04, 90),
            (0.72, 0.72, 0.72, 80),
            (0.28, 0.28, 0.28, 70)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.saturation < 0.12)
        #expect(theme.trackTitleRGB.saturation < 0.16)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("true light monochrome artwork uses a light neutral background with dark text")
    func lightMonochromeArtworkUsesLightNeutralTheme() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.70, 0.71, 0.70, 2904),
            (0.80, 0.80, 0.79, 1937),
            (0.96, 0.96, 0.96, 726),
            (0.63, 0.63, 0.63, 601),
            (0.87, 0.87, 0.87, 482),
            (0.21, 0.21, 0.21, 124)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.relativeLuminance > 0.28)
        #expect(theme.backgroundRGB.saturation < 0.12)
        #expect(theme.trackTitleRGB.relativeLuminance < 0.08)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("mostly white artwork with meaningful muted colour is not treated as monochrome")
    func mostlyWhiteArtworkWithMutedColourAvoidsMonochromePath() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.99, 0.99, 0.99, 2368),
            (0.66, 0.60, 0.55, 524),
            (0.42, 0.38, 0.33, 483),
            (0.99, 0.65, 0.81, 70),
            (0.78, 0.72, 0.65, 62),
            (0.58, 0.53, 0.51, 58),
            (0.51, 0.45, 0.40, 50)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.saturation > 0.10)
        #expect(theme.backgroundRGB.relativeLuminance > 0.18)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("two-tone artwork can use the darker tone behind lighter text")
    func twoToneArtworkUsesContrastingTones() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.02, 0.10, 0.42, 120),
            (0.94, 0.78, 0.18, 100)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.b > theme.backgroundRGB.r)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("near-white border colour does not dominate a chromatic inner artwork palette")
    func whiteBorderDoesNotDominateTheme() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.97, 0.97, 0.95, 500),
            (0.06, 0.62, 0.30, 260),
            (0.88, 0.10, 0.16, 40)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.g > theme.backgroundRGB.r)
        #expect(theme.backgroundRGB.g > theme.backgroundRGB.b)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("missing artwork uses fallback theme")
    func missingArtworkUsesFallbackTheme() {
        let theme = AlbumArtworkThemeBuilder.theme(from: [])

        #expect(theme == .fallback)
    }

    @Test("OCR matching prioritizes title over artist and album")
    func ocrMatchingPrioritizesTitleOverArtistAndAlbum() {
        let observations = [
            AlbumArtworkRecognizedText(text: "The Artist", confidence: 0.94, boundingBox: CGRect(x: 0, y: 0.1, width: 1, height: 0.2)),
            AlbumArtworkRecognizedText(text: "The Song", confidence: 0.80, boundingBox: CGRect(x: 0, y: 0.4, width: 1, height: 0.2)),
            AlbumArtworkRecognizedText(text: "The Album", confidence: 0.99, boundingBox: CGRect(x: 0, y: 0.7, width: 1, height: 0.2))
        ]

        let match = AlbumArtworkThemeBuilder.bestTextMatch(
            in: observations,
            trackTitle: "The Song",
            artistName: "The Artist",
            albumTitle: "The Album"
        )

        #expect(match?.kind == .trackTitle)
        #expect(match?.observation.text == "The Song")
    }

    @Test("OCR matching prioritizes artist over album when title is absent")
    func ocrMatchingPrioritizesArtistOverAlbumWhenTitleIsAbsent() {
        let observations = [
            AlbumArtworkRecognizedText(text: "The Album", confidence: 0.99, boundingBox: CGRect(x: 0, y: 0.2, width: 1, height: 0.2)),
            AlbumArtworkRecognizedText(text: "The Artist", confidence: 0.72, boundingBox: CGRect(x: 0, y: 0.5, width: 1, height: 0.2))
        ]

        let match = AlbumArtworkThemeBuilder.bestTextMatch(
            in: observations,
            trackTitle: "Missing Title",
            artistName: "The Artist",
            albumTitle: "The Album"
        )

        #expect(match?.kind == .artistName)
        #expect(match?.observation.text == "The Artist")
    }

    @Test("short OCR targets reject loose false positives")
    func shortOCRTargetsRejectLooseFalsePositives() {
        let falsePositive = AlbumArtworkThemeBuilder.bestTextMatch(
            in: [
                AlbumArtworkRecognizedText(text: "Golden Hour", confidence: 0.99, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.2))
            ],
            trackTitle: "Go",
            artistName: nil,
            albumTitle: nil
        )
        let exactMatch = AlbumArtworkThemeBuilder.bestTextMatch(
            in: [
                AlbumArtworkRecognizedText(text: "GO", confidence: 0.82, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.2))
            ],
            trackTitle: "Go",
            artistName: nil,
            albumTitle: nil
        )

        #expect(falsePositive == nil)
        #expect(exactMatch?.kind == .trackTitle)
    }

    @Test("text-box colour sampling ignores the local background")
    func textBoxColourSamplingIgnoresLocalBackground() throws {
        let background = AlbumArtworkRGBColor(0.05, 0.20, 0.55)
        let glyph = AlbumArtworkRGBColor(0.96, 0.78, 0.12)
        let image = try makeImage(
            width: 32,
            height: 32,
            background: background,
            foreground: glyph,
            foregroundRect: CGRect(x: 11, y: 11, width: 10, height: 10)
        )

        let sampled = AlbumArtworkThemeBuilder.sampledTextColor(
            in: image,
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            background: background,
            minimumContrast: 4.5
        )

        #expect(sampled != nil)
        #expect(sampled?.distance(to: glyph) ?? 1 < 0.18)
        #expect(sampled?.distance(to: background) ?? 0 > 0.40)
    }

    @Test("OCR success path derives readable graded text colours from one accent")
    func ocrSuccessPathDerivesReadableGradedTextColoursFromOneAccent() throws {
        let background = AlbumArtworkRGBColor(0.05, 0.20, 0.55)
        let glyph = AlbumArtworkRGBColor(0.96, 0.78, 0.12)
        let image = try makeImage(
            width: 32,
            height: 32,
            background: background,
            foreground: glyph,
            foregroundRect: CGRect(x: 8, y: 8, width: 16, height: 16)
        )
        let theme = AlbumArtworkThemeBuilder.theme(
            from: palette([
                (0.05, 0.20, 0.55, 900),
                (0.96, 0.78, 0.12, 120),
                (0.78, 0.12, 0.36, 80)
            ]),
            croppedImage: image,
            recognizedText: [
                AlbumArtworkRecognizedText(text: "Loud Song", confidence: 0.95, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
            ],
            trackTitle: "Loud Song",
            artistName: "Someone",
            albumTitle: "Something",
            options: .init()
        )

        #expect(theme.source == .ocr)
        #expect(theme.trackTitleRGB.distance(to: glyph) < 0.32)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
        #expect(theme.artistNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
        #expect(theme.albumNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
        #expect(theme.artistNameRGB.distance(to: theme.trackTitleRGB) < 0.30)
        #expect(theme.albumNameRGB.distance(to: theme.trackTitleRGB) < 0.40)
    }

    @Test("detail text colours are shades of the selected title colour")
    func detailTextColoursAreShadesOfSelectedTitleColour() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.18, 0.52, 0.76, 700),
            (0.95, 0.28, 0.12, 180),
            (0.10, 0.76, 0.26, 170)
        ]))
        let unrelatedPaletteColour = AlbumArtworkRGBColor(0.10, 0.76, 0.26)

        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
        #expect(theme.artistNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
        #expect(theme.albumNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
        #expect(theme.artistNameRGB.distance(to: theme.trackTitleRGB) < theme.artistNameRGB.distance(to: unrelatedPaletteColour))
        #expect(theme.albumNameRGB.distance(to: theme.trackTitleRGB) < theme.albumNameRGB.distance(to: unrelatedPaletteColour))
    }

    @Test("monochrome detail text colours are derived from the title colour")
    func monochromeDetailTextColoursAreDerivedFromTitleColour() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.70, 0.71, 0.70, 2904),
            (0.80, 0.80, 0.79, 1937),
            (0.96, 0.96, 0.96, 726),
            (0.63, 0.63, 0.63, 601),
            (0.87, 0.87, 0.87, 482),
            (0.21, 0.21, 0.21, 124)
        ]))

        #expect(theme.source == .monochrome)
        #expect(theme.artistNameRGB.distance(to: theme.trackTitleRGB) < 0.22)
        #expect(theme.albumNameRGB.distance(to: theme.trackTitleRGB) < 0.28)
        #expect(theme.artistNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
        #expect(theme.albumNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
    }

    @Test("mid-tone artwork uses tinted palette text instead of pure black")
    func midToneArtworkUsesTintedPaletteText() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.99, 0.99, 0.99, 2391),
            (0.66, 0.60, 0.55, 524),
            (0.43, 0.38, 0.34, 437),
            (0.59, 0.53, 0.51, 81),
            (0.99, 0.65, 0.81, 70),
            (0.78, 0.72, 0.65, 62),
            (0.51, 0.45, 0.40, 50),
            (0.99, 0.89, 0.86, 27)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.trackTitleRGB.saturation > 0.08)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
        #expect(theme.artistNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
        #expect(theme.albumNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
    }

    @Test("palette fallback uses a strong non-background accent")
    func paletteFallbackUsesStrongNonBackgroundAccent() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.18, 0.52, 0.76, 700),
            (0.95, 0.28, 0.12, 180),
            (0.90, 0.90, 0.88, 100)
        ]))

        #expect(theme.source == .paletteAccent)
        #expect(theme.trackTitleRGB.saturation > 0.20)
        #expect(theme.trackTitleRGB.distance(to: theme.backgroundRGB) > 0.20)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("muted green monochrome artwork uses tinted dark text")
    func mutedGreenMonochromeUsesTintedDarkText() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.76, 0.89, 0.73, 2214),
            (0.85, 0.87, 0.86, 1359),
            (0.96, 0.97, 0.98, 370),
            (0.77, 0.78, 0.78, 329),
            (0.69, 0.69, 0.69, 114)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.trackTitleRGB.saturation > 0.08)
        #expect(theme.trackTitleRGB.g > theme.trackTitleRGB.r)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("very low contrast palettes fall back to readable text")
    func lowContrastPaletteFallsBackToReadableText() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.18, 0.02, 0.04, 90),
            (0.20, 0.03, 0.05, 60),
            (0.16, 0.01, 0.03, 50)
        ]))

        #expect(!theme.isFallback)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
        #expect(theme.artistNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
        #expect(theme.albumNameRGB.contrastRatio(against: theme.backgroundRGB) >= 3.0)
    }

    private func palette(
        _ values: [(CGFloat, CGFloat, CGFloat, Int)]
    ) -> [AlbumArtworkPaletteColor] {
        values.map { red, green, blue, population in
            AlbumArtworkPaletteColor(
                color: AlbumArtworkRGBColor(red, green, blue),
                population: population
            )
        }
    }

    private func makeImage(
        width: Int,
        height: Int,
        background: AlbumArtworkRGBColor,
        foreground: AlbumArtworkRGBColor,
        foregroundRect: CGRect
    ) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestImageError.couldNotCreateContext
        }

        context.setFillColor(CGColor(
            red: background.r,
            green: background.g,
            blue: background.b,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(
            red: foreground.r,
            green: foreground.g,
            blue: foreground.b,
            alpha: 1
        ))
        context.fill(foregroundRect)

        guard let image = context.makeImage() else {
            throw TestImageError.couldNotCreateImage
        }
        return image
    }

    private enum TestImageError: Error {
        case couldNotCreateContext
        case couldNotCreateImage
    }
}
