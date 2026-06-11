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

    @Test("light cover stock with dark ink keeps a light background")
    func lightCoverStockWithDarkInkKeepsLightBackground() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.945, 0.929, 0.945, 2568),
            (0.035, 0.039, 0.082, 1436),
            (0.882, 0.839, 0.827, 340),
            (0.949, 0.694, 0.612, 70),
            (0.392, 0.075, 0.114, 57),
            (0.831, 0.643, 0.549, 33),
            (0.173, 0.067, 0.110, 29)
        ]))

        let darkRed = AlbumArtworkRGBColor(0.392, 0.075, 0.114)
        let salmon = AlbumArtworkRGBColor(0.949, 0.694, 0.612)

        #expect(!theme.isFallback)
        #expect(theme.backgroundRGB.relativeLuminance > 0.36)
        #expect(theme.backgroundRGB.relativeLuminance < 0.72)
        #expect(theme.trackTitleRGB.distance(to: darkRed) < theme.trackTitleRGB.distance(to: salmon))
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

    @Test("OCR matching joins multi-line artist names")
    func ocrMatchingJoinsMultiLineArtistNames() {
        let observations = [
            AlbumArtworkRecognizedText(text: "16 BIGGEST HITS", confidence: 1.0, boundingBox: CGRect(x: 0.10, y: 0.88, width: 0.77, height: 0.07)),
            AlbumArtworkRecognizedText(text: "KRIS", confidence: 1.0, boundingBox: CGRect(x: 0.73, y: 0.25, width: 0.23, height: 0.16)),
            AlbumArtworkRecognizedText(text: "KRISTOFFERSON", confidence: 1.0, boundingBox: CGRect(x: 0.27, y: 0.07, width: 0.70, height: 0.18))
        ]

        let match = AlbumArtworkThemeBuilder.bestTextMatch(
            in: observations,
            trackTitle: "Me and Bobby McGee",
            artistName: "Kris Kristofferson",
            albumTitle: "16 Biggest Hits: Kris Kristofferson"
        )

        #expect(match?.kind == .artistName)
        #expect(AlbumArtworkThemeBuilder.normalizedText(match?.observation.text ?? "") == "kris kristofferson")
        #expect(match?.observation.boundingBox.minY ?? 1 < 0.08)
        #expect(match?.observation.boundingBox.maxY ?? 0 > 0.40)
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

    @Test("text-box colour sampling treats stencil gaps as background")
    func textBoxColourSamplingTreatsStencilGapsAsBackground() throws {
        let background = AlbumArtworkRGBColor(0.07, 0.09, 0.07)
        let glyph = AlbumArtworkRGBColor(0.98, 0.98, 0.96)
        let gap = AlbumArtworkRGBColor(0.16, 0.18, 0.14)
        let image = try makeStencilImage(
            width: 64,
            height: 64,
            background: background,
            foreground: glyph,
            foregroundRect: CGRect(x: 8, y: 22, width: 44, height: 20),
            gap: gap,
            gapRects: [
                CGRect(x: 13, y: 26, width: 5, height: 12),
                CGRect(x: 24, y: 25, width: 6, height: 13),
                CGRect(x: 38, y: 27, width: 7, height: 10)
            ]
        )

        let sampled = AlbumArtworkThemeBuilder.sampledTextColor(
            in: image,
            boundingBox: CGRect(x: 0.125, y: 0.34375, width: 0.6875, height: 0.3125),
            background: background,
            minimumContrast: 4.5
        )

        #expect(sampled != nil)
        #expect(sampled?.relativeLuminance ?? 0 > 0.80)
        #expect(sampled?.distance(to: glyph) ?? 1 < 0.16)
        #expect(sampled?.distance(to: gap) ?? 0 > 0.80)
    }

    @Test("text-box colour sampling prefers glyph contrast over saturated decoration")
    func textBoxColourSamplingPrefersGlyphContrastOverSaturatedDecoration() throws {
        let localBackground = AlbumArtworkRGBColor(0.58, 0.59, 0.60)
        let glyph = AlbumArtworkRGBColor(0.16, 0.18, 0.25)
        let stripe = AlbumArtworkRGBColor(0.38, 0.15, 0.18)
        let image = try makeStencilImage(
            width: 48,
            height: 48,
            background: localBackground,
            foreground: glyph,
            foregroundRect: CGRect(x: 15, y: 27, width: 18, height: 8),
            gap: stripe,
            gapRects: [
                CGRect(x: 15, y: 18, width: 18, height: 8)
            ]
        )

        let sampled = AlbumArtworkThemeBuilder.sampledTextColor(
            in: image,
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            background: AlbumArtworkRGBColor(0.73, 0.61, 0.53),
            minimumContrast: 4.5
        )

        #expect(sampled != nil)
        #expect(sampled?.distance(to: glyph) ?? 1 < 0.20)
        #expect(sampled?.distance(to: stripe) ?? 0 > 0.20)
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

    @Test("debug report records OCR accent choice and final decisions")
    func debugReportRecordsOCRAccentChoiceAndFinalDecisions() throws {
        let background = AlbumArtworkRGBColor(0.05, 0.20, 0.55)
        let glyph = AlbumArtworkRGBColor(0.96, 0.78, 0.12)
        let image = try makeImage(
            width: 32,
            height: 32,
            background: background,
            foreground: glyph,
            foregroundRect: CGRect(x: 8, y: 8, width: 16, height: 16)
        )
        let report = AlbumArtworkThemeBuilder.debugReport(
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

        #expect(report.theme.source == .ocr)
        #expect(report.ocr.matchedKind == .trackTitle)
        #expect(report.ocr.sampledTextColor != nil)
        #expect(report.selectedAccent?.distance(to: glyph) ?? 1 < 0.32)
        #expect(report.decisions.contains { $0.contains("OCR") })
    }

    @Test("OCR pale text accent is preserved by darkening the background")
    func ocrPaleTextAccentIsPreservedByDarkeningBackground() throws {
        let localBackground = AlbumArtworkRGBColor(0.24, 0.38, 0.42)
        let glyph = AlbumArtworkRGBColor(0.78, 0.80, 0.76)
        let image = try makeImage(
            width: 64,
            height: 64,
            background: localBackground,
            foreground: glyph,
            foregroundRect: CGRect(x: 32, y: 4, width: 28, height: 10)
        )

        let report = AlbumArtworkThemeBuilder.debugReport(
            from: palette([
                (0.45, 0.59, 0.55, 1021),
                (0.75, 0.70, 0.58, 1019),
                (0.24, 0.23, 0.20, 993),
                (0.47, 0.52, 0.41, 272),
                (0.62, 0.66, 0.58, 116)
            ]),
            croppedImage: image,
            recognizedText: [
                AlbumArtworkRecognizedText(text: "JIM BOB", confidence: 1.0, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
            ],
            trackTitle: "Jo's Got Papercuts",
            artistName: "Jim Bob",
            albumTitle: "Pop Up Jim Bob",
            options: .init()
        )

        #expect(report.theme.source == .ocr)
        #expect(report.ocr.sampledTextColor?.distance(to: glyph) ?? 1 < 0.18)
        #expect(report.theme.backgroundRGB.relativeLuminance < 0.12)
        #expect(report.theme.trackTitleRGB.distance(to: glyph) < 0.18)
        #expect(report.theme.trackTitleRGB.contrastRatio(against: report.theme.backgroundRGB) >= 4.5)
    }

    @Test("OCR red artwork uses real palette background instead of synthesized pink")
    func ocrRedArtworkUsesRealPaletteBackgroundInsteadOfSynthesizedPink() throws {
        let white = AlbumArtworkRGBColor(253.0 / 255.0, 254.0 / 255.0, 254.0 / 255.0)
        let red = AlbumArtworkRGBColor(236.0 / 255.0, 42.0 / 255.0, 42.0 / 255.0)
        let blue = AlbumArtworkRGBColor(32.0 / 255.0, 68.0 / 255.0, 152.0 / 255.0)
        let pink = AlbumArtworkRGBColor(242.0 / 255.0, 168.0 / 255.0, 171.0 / 255.0)
        let image = try makeStencilImage(
            width: 64,
            height: 64,
            background: white,
            foreground: red,
            foregroundRect: CGRect(x: 8, y: 20, width: 48, height: 18),
            gap: blue,
            gapRects: [
                CGRect(x: 8, y: 20, width: 48, height: 2),
                CGRect(x: 8, y: 36, width: 48, height: 2),
                CGRect(x: 8, y: 20, width: 2, height: 18),
                CGRect(x: 54, y: 20, width: 2, height: 18)
            ]
        )

        let report = AlbumArtworkThemeBuilder.debugReport(
            from: palette([
                (238.0 / 255.0, 43.0 / 255.0, 42.0 / 255.0, 2510),
                (253.0 / 255.0, 254.0 / 255.0, 254.0 / 255.0, 2190),
                (229.0 / 255.0, 232.0 / 255.0, 240.0 / 255.0, 166),
                (49.0 / 255.0, 89.0 / 255.0, 166.0 / 255.0, 74),
                (108.0 / 255.0, 50.0 / 255.0, 99.0 / 255.0, 28),
                (124.0 / 255.0, 155.0 / 255.0, 206.0 / 255.0, 20),
                (68.0 / 255.0, 50.0 / 255.0, 117.0 / 255.0, 19),
                (204.0 / 255.0, 49.0 / 255.0, 60.0 / 255.0, 19)
            ]),
            croppedImage: image,
            recognizedText: [
                AlbumArtworkRecognizedText(
                    text: "CARTER THE UNSTOPPABLE SEX MACHINE",
                    confidence: 1.0,
                    boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1)
                )
            ],
            trackTitle: "Re - Educating Rita (2012 Remaster)",
            artistName: "Carter the Unstoppable Sex Machine",
            albumTitle: "30 Something (Deluxe Version)",
            options: .init()
        )

        #expect(report.theme.source == .ocr)
        #expect(report.ocr.sampledTextColor?.distance(to: red) ?? 1 < 0.12)
        #expect(report.theme.backgroundRGB.distance(to: white) < report.theme.backgroundRGB.distance(to: pink))
        #expect(report.theme.backgroundRGB.relativeLuminance > 0.80)
        #expect(report.theme.trackTitleRGB.distance(to: red) < report.theme.trackTitleRGB.distance(to: blue))
        #expect(report.theme.trackTitleRGB.contrastRatio(against: report.theme.backgroundRGB) >= 4.5)
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

    @Test("monochrome artwork uses OCR text colour when metadata text is found")
    func monochromeArtworkUsesOCRTextColourWhenMetadataTextIsFound() throws {
        let localBackground = AlbumArtworkRGBColor(0.86, 0.86, 0.85)
        let glyph = AlbumArtworkRGBColor(0.03, 0.03, 0.035)
        let image = try makeImage(
            width: 64,
            height: 64,
            background: localBackground,
            foreground: glyph,
            foregroundRect: CGRect(x: 8, y: 20, width: 48, height: 18)
        )

        let report = AlbumArtworkThemeBuilder.debugReport(
            from: palette([
                (0.86, 0.86, 0.85, 2600),
                (0.06, 0.06, 0.07, 420),
                (0.55, 0.55, 0.54, 220)
            ]),
            croppedImage: image,
            recognizedText: [
                AlbumArtworkRecognizedText(text: "WHITE LIGHT", confidence: 1.0, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
            ],
            trackTitle: "White Light",
            artistName: "Mono Artist",
            albumTitle: "Mono Album",
            options: .init()
        )

        #expect(report.monochrome?.isMonochrome == true)
        #expect(report.theme.source == .ocr)
        #expect(report.ocr.sampledTextColor?.distance(to: glyph) ?? 1 < 0.12)
        #expect(report.theme.trackTitleRGB.distance(to: glyph) < 0.12)
        #expect(report.theme.backgroundRGB.distance(to: localBackground) < 0.12)
        #expect(report.theme.trackTitleRGB.contrastRatio(against: report.theme.backgroundRGB) >= 4.5)
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

    @Test("full-screen control palette keeps the accent in button surfaces")
    func fullScreenControlPaletteKeepsAccentInButtonSurfaces() throws {
        let theme = AlbumArtworkTheme(
            backgroundRGB: AlbumArtworkRGBColor(0.04, 0.04, 0.08),
            trackTitleRGB: AlbumArtworkRGBColor(0.95, 0.69, 0.61),
            artistNameRGB: AlbumArtworkRGBColor(0.76, 0.57, 0.52),
            albumNameRGB: AlbumArtworkRGBColor(0.70, 0.55, 0.51),
            isFallback: false,
            source: .paletteAccent
        )
        let palette = try #require(FullScreenPlayerControlPalette(theme: theme))

        #expect(palette.surfaceRGB.distance(to: theme.trackTitleRGB) < 0.28)
        #expect(palette.surfaceRGB.saturation > 0.25)
        #expect(palette.surfaceForegroundRGB.contrastRatio(against: palette.surfaceRGB) >= 4.5)
        #expect(palette.selectedForegroundRGB.contrastRatio(against: palette.accentRGB) >= 4.5)
    }

    @Test("low-information dark dominant yields to a vivid background colour")
    func lowInformationDarkDominantYieldsToVividBackgroundColour() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (0.173, 0.149, 0.122, 2046),
            (0.788, 0.490, 0.204, 181),
            (0.286, 0.216, 0.157, 149),
            (0.718, 0.361, 0.173, 75),
            (0.231, 0.549, 0.616, 28),
            (0.392, 0.263, 0.173, 24)
        ]))
        let dominantBrown = AlbumArtworkRGBColor(0.173, 0.149, 0.122)
        let orangeAccent = AlbumArtworkRGBColor(0.788, 0.490, 0.204)

        #expect(theme.source == .paletteAccent)
        #expect(theme.backgroundRGB.distance(to: orangeAccent) < theme.backgroundRGB.distance(to: dominantBrown))
        #expect(theme.backgroundRGB.saturation > 0.30)
        #expect(theme.trackTitleRGB.contrastRatio(against: theme.backgroundRGB) >= 4.5)
    }

    @Test("palette accent fallback prefers real palette foreground over synthesized pastel")
    func paletteAccentFallbackPrefersRealPaletteForegroundOverSynthesizedPastel() {
        let theme = AlbumArtworkThemeBuilder.theme(from: palette([
            (13.0 / 255.0, 12.0 / 255.0, 12.0 / 255.0, 1349),
            (39.0 / 255.0, 33.0 / 255.0, 27.0 / 255.0, 379),
            (64.0 / 255.0, 51.0 / 255.0, 37.0 / 255.0, 219),
            (190.0 / 255.0, 56.0 / 255.0, 37.0 / 255.0, 169),
            (253.0 / 255.0, 253.0 / 255.0, 253.0 / 255.0, 165),
            (1.0 / 255.0, 77.0 / 255.0, 233.0 / 255.0, 99)
        ]))
        let redAccent = AlbumArtworkRGBColor(190.0 / 255.0, 56.0 / 255.0, 37.0 / 255.0)
        let whiteAccent = AlbumArtworkRGBColor(253.0 / 255.0, 253.0 / 255.0, 253.0 / 255.0)

        #expect(theme.source == .paletteAccent)
        #expect(theme.trackTitleRGB.distance(to: whiteAccent) < theme.trackTitleRGB.distance(to: redAccent))
        #expect(theme.trackTitleRGB.saturation < 0.15)
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

    private func makeStencilImage(
        width: Int,
        height: Int,
        background: AlbumArtworkRGBColor,
        foreground: AlbumArtworkRGBColor,
        foregroundRect: CGRect,
        gap: AlbumArtworkRGBColor,
        gapRects: [CGRect]
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

        context.setFillColor(CGColor(red: background.r, green: background.g, blue: background.b, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: foreground.r, green: foreground.g, blue: foreground.b, alpha: 1))
        context.fill(foregroundRect)
        context.setFillColor(CGColor(red: gap.r, green: gap.g, blue: gap.b, alpha: 1))
        for rect in gapRects {
            context.fill(rect)
        }

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
