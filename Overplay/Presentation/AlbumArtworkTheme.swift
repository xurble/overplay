import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
@preconcurrency import Vision

nonisolated enum AlbumArtworkThemeDiagnostics {
    static func log(_ message: String) {
        _ = message
    }

    static func describe(_ color: AlbumArtworkRGBColor) -> String {
        let red = Int((color.r * 255).rounded())
        let green = Int((color.g * 255).rounded())
        let blue = Int((color.b * 255).rounded())
        return "rgb(\(red),\(green),\(blue)) lum=\(format(color.relativeLuminance)) sat=\(format(color.saturation))"
    }

    static func format(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
    }
}

nonisolated enum AlbumArtworkThemeSource: String, Codable, Equatable, Sendable {
    case fallback
    case monochrome
    case ocr
    case paletteAccent
    case palette
}

nonisolated struct AlbumArtworkTheme: Codable, Equatable, Sendable {
    let backgroundRGB: AlbumArtworkRGBColor
    let trackTitleRGB: AlbumArtworkRGBColor
    let artistNameRGB: AlbumArtworkRGBColor
    let albumNameRGB: AlbumArtworkRGBColor
    let isFallback: Bool
    let source: AlbumArtworkThemeSource

    var background: Color { backgroundRGB.color }
    var trackTitle: Color { trackTitleRGB.color }
    var artistName: Color { artistNameRGB.color }
    var albumName: Color { albumNameRGB.color }

    static let fallback = AlbumArtworkTheme(
        backgroundRGB: .defaultPlayerBackground,
        trackTitleRGB: .white,
        artistNameRGB: .init(0.84, 0.84, 0.88),
        albumNameRGB: .init(0.68, 0.68, 0.74),
        isFallback: true,
        source: .fallback
    )
}

nonisolated struct AlbumArtworkThemeInput: Sendable {
    var artworkData: Data
    var artworkURLTemplate: String?
    var trackTitle: String?
    var artistName: String?
    var albumTitle: String?
    var options: AlbumArtworkThemeBuilder.Options

    init(
        artworkData: Data,
        artworkURLTemplate: String? = nil,
        trackTitle: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        options: AlbumArtworkThemeBuilder.Options = .init()
    ) {
        self.artworkData = artworkData
        self.artworkURLTemplate = artworkURLTemplate
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.options = options
    }
}

nonisolated struct AlbumArtworkRGBColor: Codable, Equatable, Sendable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    var color: Color {
        Color(red: Double(r), green: Double(g), blue: Double(b))
    }

    var relativeLuminance: CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    var brightness: CGFloat {
        max(r, g, b)
    }

    var saturation: CGFloat {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        guard maximum > 0 else { return 0 }
        return (maximum - minimum) / maximum
    }

    private var hsb: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum

        let hue: CGFloat
        if delta == 0 {
            hue = 0
        } else if maximum == r {
            hue = (((g - b) / delta).truncatingRemainder(dividingBy: 6)) / 6
        } else if maximum == g {
            hue = (((b - r) / delta) + 2) / 6
        } else {
            hue = (((r - g) / delta) + 4) / 6
        }

        return (
            hue: hue < 0 ? hue + 1 : hue,
            saturation: maximum == 0 ? 0 : delta / maximum,
            brightness: maximum
        )
    }

    var isNearWhite: Bool {
        brightness > 0.88 && saturation < 0.18
    }

    var isNearBlack: Bool {
        brightness < 0.08
    }

    var isNeutral: Bool {
        saturation < 0.12
    }

    static let white = AlbumArtworkRGBColor(0.96, 0.96, 0.98)
    static let black = AlbumArtworkRGBColor(0.06, 0.06, 0.07)
    static let defaultPlayerBackground = AlbumArtworkRGBColor(0.08, 0.08, 0.10)

    func contrastRatio(against other: AlbumArtworkRGBColor) -> CGFloat {
        let l1 = relativeLuminance
        let l2 = other.relativeLuminance
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func distance(to other: AlbumArtworkRGBColor) -> CGFloat {
        let redDistance = r - other.r
        let greenDistance = g - other.g
        let blueDistance = b - other.b
        return sqrt(redDistance * redDistance + greenDistance * greenDistance + blueDistance * blueDistance)
    }

    func mixed(with other: AlbumArtworkRGBColor, amount: CGFloat) -> AlbumArtworkRGBColor {
        let clampedAmount = min(max(amount, 0), 1)
        return AlbumArtworkRGBColor(
            r + ((other.r - r) * clampedAmount),
            g + ((other.g - g) * clampedAmount),
            b + ((other.b - b) * clampedAmount)
        )
    }

    func darkened(_ amount: CGFloat) -> AlbumArtworkRGBColor {
        mixed(with: .black, amount: amount)
    }

    func lightened(_ amount: CGFloat) -> AlbumArtworkRGBColor {
        mixed(with: .white, amount: amount)
    }

    func desaturated(_ amount: CGFloat) -> AlbumArtworkRGBColor {
        let grey = AlbumArtworkRGBColor(relativeLuminance, relativeLuminance, relativeLuminance)
        return mixed(with: grey, amount: amount)
    }

    func adjustedToward(
        _ target: AlbumArtworkRGBColor,
        targetLuminance: CGFloat,
        maxAmount: CGFloat
    ) -> AlbumArtworkRGBColor {
        var bestColor = self
        var bestDistance = abs(relativeLuminance - targetLuminance)

        for step in 1...20 {
            let amount = maxAmount * (CGFloat(step) / 20)
            let candidate = mixed(with: target, amount: amount)
            let distance = abs(candidate.relativeLuminance - targetLuminance)
            if distance < bestDistance {
                bestColor = candidate
                bestDistance = distance
            }
        }

        return bestColor
    }

    func hueShifted(_ amount: CGFloat, saturationMultiplier: CGFloat = 1, brightnessMultiplier: CGFloat = 1) -> AlbumArtworkRGBColor {
        let components = hsb
        let hue = (components.hue + amount).truncatingRemainder(dividingBy: 1)
        return Self.fromHSB(
            hue: hue < 0 ? hue + 1 : hue,
            saturation: min(max(components.saturation * saturationMultiplier, 0), 1),
            brightness: min(max(components.brightness * brightnessMultiplier, 0), 1)
        )
    }

    private static func fromHSB(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> AlbumArtworkRGBColor {
        guard saturation > 0 else {
            return AlbumArtworkRGBColor(brightness, brightness, brightness)
        }

        let scaledHue = hue * 6
        let sector = floor(scaledHue)
        let fraction = scaledHue - sector
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        switch Int(sector) % 6 {
        case 0: return AlbumArtworkRGBColor(brightness, t, p)
        case 1: return AlbumArtworkRGBColor(q, brightness, p)
        case 2: return AlbumArtworkRGBColor(p, brightness, t)
        case 3: return AlbumArtworkRGBColor(p, q, brightness)
        case 4: return AlbumArtworkRGBColor(t, p, brightness)
        default: return AlbumArtworkRGBColor(brightness, p, q)
        }
    }
}

nonisolated struct AlbumArtworkPaletteColor: Equatable, Sendable {
    var color: AlbumArtworkRGBColor
    var population: Int
}

nonisolated struct AlbumArtworkRecognizedText: Equatable, Sendable {
    enum MatchKind: Int, Sendable {
        case trackTitle = 0
        case artistName = 1
        case albumTitle = 2

        var debugLabel: String {
            switch self {
            case .trackTitle: "track title"
            case .artistName: "artist name"
            case .albumTitle: "album name"
            }
        }
    }

    var text: String
    var confidence: CGFloat
    var boundingBox: CGRect
}

nonisolated struct AlbumArtworkTextMatch: Equatable, Sendable {
    var kind: AlbumArtworkRecognizedText.MatchKind
    var observation: AlbumArtworkRecognizedText
}

nonisolated struct AlbumArtworkThemeDebugPaletteEntry: Equatable, Sendable {
    var color: AlbumArtworkRGBColor
    var population: Int
}

nonisolated struct AlbumArtworkThemeDebugImageSize: Equatable, Sendable {
    var width: Int
    var height: Int
}

nonisolated struct AlbumArtworkThemeDebugTarget: Equatable, Sendable {
    var label: String
    var original: String?
    var normalized: String
}

nonisolated struct AlbumArtworkThemeDebugMonochromeAnalysis: Equatable, Sendable {
    var averageSaturation: CGFloat
    var neutralShare: CGFloat
    var chromaticShare: CGFloat
    var isMonochrome: Bool
}

nonisolated struct AlbumArtworkThemeDebugOCR: Equatable, Sendable {
    var observations: [AlbumArtworkRecognizedText]
    var matchedKind: AlbumArtworkRecognizedText.MatchKind?
    var matchedText: String?
    var matchedConfidence: CGFloat?
    var sampledTextColor: AlbumArtworkRGBColor?
    var localBackgroundColor: AlbumArtworkRGBColor?
    var localPalette: [AlbumArtworkThemeDebugPaletteEntry]
    var status: String
}

nonisolated struct AlbumArtworkThemeDebugReport: Equatable, Sendable {
    var generatedAt: Date
    var normalizedArtworkURL: String?
    var artworkByteCount: Int
    var artworkDataHash: String?
    var downsampledSize: AlbumArtworkThemeDebugImageSize?
    var croppedSize: AlbumArtworkThemeDebugImageSize?
    var rawPalette: [AlbumArtworkThemeDebugPaletteEntry]
    var cleanedPalette: [AlbumArtworkThemeDebugPaletteEntry]
    var textCandidates: [AlbumArtworkThemeDebugPaletteEntry]
    var normalizedTargets: [AlbumArtworkThemeDebugTarget]
    var monochrome: AlbumArtworkThemeDebugMonochromeAnalysis?
    var backgroundCandidate: AlbumArtworkRGBColor?
    var background: AlbumArtworkRGBColor?
    var selectedAccent: AlbumArtworkRGBColor?
    var preferredAccent: AlbumArtworkRGBColor?
    var ocr: AlbumArtworkThemeDebugOCR
    var decisions: [String]
    var theme: AlbumArtworkTheme
    var errorMessage: String?

    static func failure(
        normalizedArtworkURL: String?,
        artworkByteCount: Int,
        artworkDataHash: String?,
        errorMessage: String
    ) -> AlbumArtworkThemeDebugReport {
        AlbumArtworkThemeDebugReport(
            generatedAt: .now,
            normalizedArtworkURL: normalizedArtworkURL,
            artworkByteCount: artworkByteCount,
            artworkDataHash: artworkDataHash,
            downsampledSize: nil,
            croppedSize: nil,
            rawPalette: [],
            cleanedPalette: [],
            textCandidates: [],
            normalizedTargets: [],
            monochrome: nil,
            backgroundCandidate: nil,
            background: nil,
            selectedAccent: nil,
            preferredAccent: nil,
            ocr: AlbumArtworkThemeDebugOCR(
                observations: [],
                matchedKind: nil,
                matchedText: nil,
                matchedConfidence: nil,
                sampledTextColor: nil,
                localBackgroundColor: nil,
                localPalette: [],
                status: "OCR not run because artwork could not be analysed."
            ),
            decisions: [errorMessage],
            theme: .fallback,
            errorMessage: errorMessage
        )
    }
}

nonisolated enum AlbumArtworkThemeBuilder {
    static let algorithmVersion = 14
    private static let paletteAccentMaximumAdjustmentDistance: CGFloat = 0.30

    struct Options: Equatable, Sendable {
        var requiresIncreasedContrast = false

        var titleMinimumContrast: CGFloat {
            requiresIncreasedContrast ? 7.0 : 4.5
        }

        var detailMinimumContrast: CGFloat {
            requiresIncreasedContrast ? 4.5 : 3.0
        }
    }

    static func theme(fromArtworkData data: Data, options: Options = Options()) -> AlbumArtworkTheme {
        theme(from: AlbumArtworkThemeInput(artworkData: data, options: options))
    }

    static func theme(from input: AlbumArtworkThemeInput) -> AlbumArtworkTheme {
        guard let image = downsampledImage(from: input.artworkData, maxDimension: 100),
              let croppedImage = cropped(image, removingOuterPercent: 0.08) else {
            AlbumArtworkThemeDiagnostics.log("builder fallback: could not decode/downsample artwork data bytes=\(input.artworkData.count)")
            return .fallback
        }

        AlbumArtworkThemeDiagnostics.log(
            "builder image: downsampled=\(image.width)x\(image.height) cropped=\(croppedImage.width)x\(croppedImage.height) bytes=\(input.artworkData.count)"
        )
        let palette = extractPalette(from: croppedImage, maxColors: 8)
        logPalette("builder raw palette", palette)
        let textImage = downsampledImage(from: input.artworkData, maxDimension: 512) ?? image
        AlbumArtworkThemeDiagnostics.log("builder ocr image: \(textImage.width)x\(textImage.height) uncropped")
        let recognizedText = recognizeText(in: textImage)
        return theme(
            from: palette,
            croppedImage: textImage,
            recognizedText: recognizedText,
            trackTitle: input.trackTitle,
            artistName: input.artistName,
            albumTitle: input.albumTitle,
            options: input.options
        )
    }

    static func debugReport(from input: AlbumArtworkThemeInput, artworkDataHash: String? = nil) -> AlbumArtworkThemeDebugReport {
        let targets = debugTargets(
            trackTitle: input.trackTitle,
            artistName: input.artistName,
            albumTitle: input.albumTitle
        )
        guard let image = downsampledImage(from: input.artworkData, maxDimension: 100),
              let croppedImage = cropped(image, removingOuterPercent: 0.08) else {
            return .failure(
                normalizedArtworkURL: input.artworkURLTemplate,
                artworkByteCount: input.artworkData.count,
                artworkDataHash: artworkDataHash,
                errorMessage: "Could not decode or downsample artwork data."
            )
        }

        let rawPalette = extractPalette(from: croppedImage, maxColors: 8)
        let textImage = downsampledImage(from: input.artworkData, maxDimension: 512) ?? image
        let recognizedText = recognizeText(in: textImage)
        let cleanedPalette = cleaned(rawPalette)
        guard !cleanedPalette.isEmpty else {
            return .failure(
                normalizedArtworkURL: input.artworkURLTemplate,
                artworkByteCount: input.artworkData.count,
                artworkDataHash: artworkDataHash,
                errorMessage: "Palette extraction returned no usable colours after cleaning."
            )
        }

        let monochromeAnalysis = monochromeAnalysis(for: cleanedPalette)
        var decisions = [
            "Downsampled artwork to \(image.width)x\(image.height) and cropped outer 8% to \(croppedImage.width)x\(croppedImage.height).",
            "Ran OCR on uncropped \(textImage.width)x\(textImage.height) artwork so edge text and small type survive analysis.",
            "Extracted \(rawPalette.count) raw palette colours; \(cleanedPalette.count) remained after duplicate/noise cleanup."
        ]

        if monochromeAnalysis.isMonochrome {
            decisions.append("Classified artwork as monochrome; checking OCR before using the neutral fallback.")
            let provisionalBackground = monochromeBackground(from: cleanedPalette)
            let ocr = debugOCR(
                croppedImage: textImage,
                recognizedText: recognizedText,
                background: provisionalBackground,
                trackTitle: input.trackTitle,
                artistName: input.artistName,
                albumTitle: input.albumTitle,
                options: input.options
            )
            let theme: AlbumArtworkTheme
            if let sampledTextColor = ocr.sampledTextColor {
                let background = monochromeBackground(
                    from: cleanedPalette,
                    for: sampledTextColor,
                    minimumContrast: input.options.titleMinimumContrast
                )
                decisions.append("OCR matched \(ocr.matchedKind?.debugLabel ?? "metadata") text in monochrome artwork and selected sampled glyph colour \(debugColorSummary(sampledTextColor)).")
                decisions.append("Selected monochrome palette background \(debugColorSummary(background)) for the OCR text colour.")
                theme = self.theme(
                    background: background,
                    titleAccent: sampledTextColor,
                    options: input.options,
                    source: "ocr"
                )
            } else {
                decisions.append("OCR did not provide a usable colour for monochrome artwork; used neutral background plus readable title-derived detail colours.")
                theme = monochromeTheme(from: cleanedPalette, options: input.options)
            }
            return AlbumArtworkThemeDebugReport(
                generatedAt: .now,
                normalizedArtworkURL: input.artworkURLTemplate,
                artworkByteCount: input.artworkData.count,
                artworkDataHash: artworkDataHash,
                downsampledSize: AlbumArtworkThemeDebugImageSize(width: image.width, height: image.height),
                croppedSize: AlbumArtworkThemeDebugImageSize(width: croppedImage.width, height: croppedImage.height),
                rawPalette: debugPalette(rawPalette),
                cleanedPalette: debugPalette(cleanedPalette),
                textCandidates: debugPalette(textCandidates(from: cleanedPalette, background: theme.backgroundRGB)),
                normalizedTargets: targets,
                monochrome: monochromeAnalysis,
                backgroundCandidate: provisionalBackground,
                background: theme.backgroundRGB,
                selectedAccent: theme.trackTitleRGB,
                preferredAccent: accentColor(from: cleanedPalette),
                ocr: ocr,
                decisions: decisions,
                theme: theme,
                errorMessage: nil
            )
        }

        decisions.append("Artwork was not monochrome; choosing a chromatic background and foreground accent.")
        let backgroundCandidate = chooseBackgroundColor(from: cleanedPalette)
        let background = adjustBackground(backgroundCandidate)
        let preferredAccent = accentColor(from: cleanedPalette, avoiding: backgroundCandidate)
        let textCandidates = textCandidates(from: cleanedPalette, background: background, avoiding: [backgroundCandidate])
        let ocr = debugOCR(
            croppedImage: textImage,
            recognizedText: recognizedText,
            background: background,
            trackTitle: input.trackTitle,
            artistName: input.artistName,
            albumTitle: input.albumTitle,
            options: input.options
        )
        decisions.append("Background candidate \(debugColorSummary(backgroundCandidate)) adjusted to \(debugColorSummary(background)).")

        let selectedAccent: AlbumArtworkRGBColor
        let theme: AlbumArtworkTheme
        if let sampledTextColor = ocr.sampledTextColor {
            selectedAccent = sampledTextColor
            decisions.append("OCR matched \(ocr.matchedKind?.debugLabel ?? "metadata") text and selected sampled glyph colour \(debugColorSummary(sampledTextColor)).")
            let themeBackground = ocrBackground(
                from: cleanedPalette,
                raw: backgroundCandidate,
                adjusted: background,
                accent: sampledTextColor,
                minimumContrast: input.options.titleMinimumContrast
            )
            if themeBackground != background {
                decisions.append("Selected palette background \(debugColorSummary(themeBackground)) for the OCR text colour instead of synthesizing a contrast colour.")
            }
            theme = self.theme(
                background: themeBackground,
                titleAccent: sampledTextColor,
                options: input.options,
                source: "ocr"
            )
        } else if let paletteAccent = strongestForegroundAccent(
            from: textCandidates,
            background: background,
            avoiding: [backgroundCandidate]
        ) ?? preferredAccent {
            selectedAccent = paletteAccent
            decisions.append("OCR did not provide a usable accent; selected strongest palette foreground accent \(debugColorSummary(paletteAccent)).")
            let themeBackground = preferredBackground(
                raw: backgroundCandidate,
                adjusted: background,
                accent: paletteAccent,
                minimumContrast: input.options.titleMinimumContrast
            )
            if themeBackground == backgroundCandidate, backgroundCandidate != background {
                decisions.append("Kept the original background candidate because it already gives the selected accent readable contrast.")
            }
            theme = self.theme(
                background: themeBackground,
                titleAccent: paletteAccent,
                fallbackTitleAccent: directlyReadablePaletteColor(
                    from: textCandidates,
                    against: themeBackground,
                    minimumContrast: input.options.titleMinimumContrast
                ),
                maximumTitleAdjustmentDistance: paletteAccentMaximumAdjustmentDistance,
                options: input.options,
                source: "palette-accent"
            )
            if theme.trackTitleRGB.distance(to: paletteAccent) > paletteAccentMaximumAdjustmentDistance {
                decisions.append("The strongest palette accent needed too much colour shifting for readable text; used a directly readable palette colour \(debugColorSummary(theme.trackTitleRGB)) instead.")
            }
        } else {
            let fallbackAccent = chooseReadableColor(
                from: textCandidates,
                against: background,
                minimumContrast: input.options.titleMinimumContrast,
                fallback: preferredForeground(for: background, accent: preferredAccent)
            )
            selectedAccent = fallbackAccent
            decisions.append("No strong accent survived filtering; selected readable fallback foreground \(debugColorSummary(fallbackAccent)).")
            theme = self.theme(
                background: background,
                titleAccent: fallbackAccent,
                options: input.options,
                source: "palette"
            )
        }
        if theme.backgroundRGB != background {
            if theme.trackTitleRGB.distance(to: selectedAccent) > paletteAccentMaximumAdjustmentDistance {
                decisions.append("Adjusted background again to \(debugColorSummary(theme.backgroundRGB)) during final contrast balancing.")
            } else {
                decisions.append("Adjusted background again to \(debugColorSummary(theme.backgroundRGB)) so the selected accent could remain closer to its artwork colour.")
            }
        }
        decisions.append("Derived artist and album colours as softened shades of the selected title colour.")

        return AlbumArtworkThemeDebugReport(
            generatedAt: .now,
            normalizedArtworkURL: input.artworkURLTemplate,
            artworkByteCount: input.artworkData.count,
            artworkDataHash: artworkDataHash,
            downsampledSize: AlbumArtworkThemeDebugImageSize(width: image.width, height: image.height),
            croppedSize: AlbumArtworkThemeDebugImageSize(width: croppedImage.width, height: croppedImage.height),
            rawPalette: debugPalette(rawPalette),
            cleanedPalette: debugPalette(cleanedPalette),
            textCandidates: debugPalette(textCandidates),
            normalizedTargets: targets,
            monochrome: monochromeAnalysis,
            backgroundCandidate: backgroundCandidate,
            background: theme.backgroundRGB,
            selectedAccent: selectedAccent,
            preferredAccent: preferredAccent,
            ocr: ocr,
            decisions: decisions,
            theme: theme,
            errorMessage: nil
        )
    }

    static func debugReport(
        from palette: [AlbumArtworkPaletteColor],
        croppedImage: CGImage? = nil,
        recognizedText: [AlbumArtworkRecognizedText] = [],
        trackTitle: String? = nil,
        artistName: String? = nil,
        albumTitle: String? = nil,
        options: Options = Options()
    ) -> AlbumArtworkThemeDebugReport {
        let targets = debugTargets(
            trackTitle: trackTitle,
            artistName: artistName,
            albumTitle: albumTitle
        )
        let cleanedPalette = cleaned(palette)
        guard !cleanedPalette.isEmpty else {
            return .failure(
                normalizedArtworkURL: nil,
                artworkByteCount: 0,
                artworkDataHash: nil,
                errorMessage: "Palette extraction returned no usable colours after cleaning."
            )
        }

        let monochromeAnalysis = monochromeAnalysis(for: cleanedPalette)
        var decisions = [
            "Using supplied palette for diagnostics.",
            "Extracted \(palette.count) raw palette colours; \(cleanedPalette.count) remained after duplicate/noise cleanup."
        ]

        if monochromeAnalysis.isMonochrome {
            decisions.append("Classified artwork as monochrome; checking OCR before using the neutral fallback.")
            let provisionalBackground = monochromeBackground(from: cleanedPalette)
            let ocr = debugOCR(
                croppedImage: croppedImage,
                recognizedText: recognizedText,
                background: provisionalBackground,
                trackTitle: trackTitle,
                artistName: artistName,
                albumTitle: albumTitle,
                options: options
            )
            let theme: AlbumArtworkTheme
            if let sampledTextColor = ocr.sampledTextColor {
                let background = monochromeBackground(
                    from: cleanedPalette,
                    for: sampledTextColor,
                    minimumContrast: options.titleMinimumContrast
                )
                decisions.append("OCR matched \(ocr.matchedKind?.debugLabel ?? "metadata") text in monochrome artwork and selected sampled glyph colour \(debugColorSummary(sampledTextColor)).")
                decisions.append("Selected monochrome palette background \(debugColorSummary(background)) for the OCR text colour.")
                theme = self.theme(
                    background: background,
                    titleAccent: sampledTextColor,
                    options: options,
                    source: "ocr"
                )
            } else {
                decisions.append("OCR did not provide a usable colour for monochrome artwork; used neutral background plus readable title-derived detail colours.")
                theme = monochromeTheme(from: cleanedPalette, options: options)
            }
            return AlbumArtworkThemeDebugReport(
                generatedAt: .now,
                normalizedArtworkURL: nil,
                artworkByteCount: 0,
                artworkDataHash: nil,
                downsampledSize: nil,
                croppedSize: croppedImage.map { AlbumArtworkThemeDebugImageSize(width: $0.width, height: $0.height) },
                rawPalette: debugPalette(palette),
                cleanedPalette: debugPalette(cleanedPalette),
                textCandidates: debugPalette(textCandidates(from: cleanedPalette, background: theme.backgroundRGB)),
                normalizedTargets: targets,
                monochrome: monochromeAnalysis,
                backgroundCandidate: provisionalBackground,
                background: theme.backgroundRGB,
                selectedAccent: theme.trackTitleRGB,
                preferredAccent: accentColor(from: cleanedPalette),
                ocr: ocr,
                decisions: decisions,
                theme: theme,
                errorMessage: nil
            )
        }

        decisions.append("Artwork was not monochrome; choosing a chromatic background and foreground accent.")
        let backgroundCandidate = chooseBackgroundColor(from: cleanedPalette)
        let background = adjustBackground(backgroundCandidate)
        let preferredAccent = accentColor(from: cleanedPalette, avoiding: backgroundCandidate)
        let textCandidates = textCandidates(from: cleanedPalette, background: background, avoiding: [backgroundCandidate])
        let ocr = debugOCR(
            croppedImage: croppedImage,
            recognizedText: recognizedText,
            background: background,
            trackTitle: trackTitle,
            artistName: artistName,
            albumTitle: albumTitle,
            options: options
        )
        decisions.append("Background candidate \(debugColorSummary(backgroundCandidate)) adjusted to \(debugColorSummary(background)).")

        let selectedAccent: AlbumArtworkRGBColor
        let theme: AlbumArtworkTheme
        if let sampledTextColor = ocr.sampledTextColor {
            selectedAccent = sampledTextColor
            decisions.append("OCR matched \(ocr.matchedKind?.debugLabel ?? "metadata") text and selected sampled glyph colour \(debugColorSummary(sampledTextColor)).")
            let themeBackground = ocrBackground(
                from: cleanedPalette,
                raw: backgroundCandidate,
                adjusted: background,
                accent: sampledTextColor,
                minimumContrast: options.titleMinimumContrast
            )
            if themeBackground != background {
                decisions.append("Selected palette background \(debugColorSummary(themeBackground)) for the OCR text colour instead of synthesizing a contrast colour.")
            }
            theme = self.theme(
                background: themeBackground,
                titleAccent: sampledTextColor,
                options: options,
                source: "ocr"
            )
        } else if let paletteAccent = strongestForegroundAccent(
            from: textCandidates,
            background: background,
            avoiding: [backgroundCandidate]
        ) ?? preferredAccent {
            selectedAccent = paletteAccent
            decisions.append("OCR did not provide a usable accent; selected strongest palette foreground accent \(debugColorSummary(paletteAccent)).")
            let themeBackground = preferredBackground(
                raw: backgroundCandidate,
                adjusted: background,
                accent: paletteAccent,
                minimumContrast: options.titleMinimumContrast
            )
            if themeBackground == backgroundCandidate, backgroundCandidate != background {
                decisions.append("Kept the original background candidate because it already gives the selected accent readable contrast.")
            }
            theme = self.theme(
                background: themeBackground,
                titleAccent: paletteAccent,
                fallbackTitleAccent: directlyReadablePaletteColor(
                    from: textCandidates,
                    against: themeBackground,
                    minimumContrast: options.titleMinimumContrast
                ),
                maximumTitleAdjustmentDistance: paletteAccentMaximumAdjustmentDistance,
                options: options,
                source: "palette-accent"
            )
            if theme.trackTitleRGB.distance(to: paletteAccent) > paletteAccentMaximumAdjustmentDistance {
                decisions.append("The strongest palette accent needed too much colour shifting for readable text; used a directly readable palette colour \(debugColorSummary(theme.trackTitleRGB)) instead.")
            }
        } else {
            let fallbackAccent = chooseReadableColor(
                from: textCandidates,
                against: background,
                minimumContrast: options.titleMinimumContrast,
                fallback: preferredForeground(for: background, accent: preferredAccent)
            )
            selectedAccent = fallbackAccent
            decisions.append("No strong accent survived filtering; selected readable fallback foreground \(debugColorSummary(fallbackAccent)).")
            theme = self.theme(
                background: background,
                titleAccent: fallbackAccent,
                options: options,
                source: "palette"
            )
        }
        if theme.backgroundRGB != background {
            if theme.trackTitleRGB.distance(to: selectedAccent) > paletteAccentMaximumAdjustmentDistance {
                decisions.append("Adjusted background again to \(debugColorSummary(theme.backgroundRGB)) during final contrast balancing.")
            } else {
                decisions.append("Adjusted background again to \(debugColorSummary(theme.backgroundRGB)) so the selected accent could remain closer to its artwork colour.")
            }
        }
        decisions.append("Derived artist and album colours as softened shades of the selected title colour.")

        return AlbumArtworkThemeDebugReport(
            generatedAt: .now,
            normalizedArtworkURL: nil,
            artworkByteCount: 0,
            artworkDataHash: nil,
            downsampledSize: nil,
            croppedSize: croppedImage.map { AlbumArtworkThemeDebugImageSize(width: $0.width, height: $0.height) },
            rawPalette: debugPalette(palette),
            cleanedPalette: debugPalette(cleanedPalette),
            textCandidates: debugPalette(textCandidates),
            normalizedTargets: targets,
            monochrome: monochromeAnalysis,
            backgroundCandidate: backgroundCandidate,
            background: theme.backgroundRGB,
            selectedAccent: selectedAccent,
            preferredAccent: preferredAccent,
            ocr: ocr,
            decisions: decisions,
            theme: theme,
            errorMessage: nil
        )
    }

    static func theme(
        from palette: [AlbumArtworkPaletteColor],
        options: Options = Options()
    ) -> AlbumArtworkTheme {
        theme(
            from: palette,
            croppedImage: nil,
            recognizedText: [],
            trackTitle: nil,
            artistName: nil,
            albumTitle: nil,
            options: options
        )
    }

    static func normalizedText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func bestTextMatch(
        in observations: [AlbumArtworkRecognizedText],
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?
    ) -> AlbumArtworkTextMatch? {
        let targets: [(AlbumArtworkRecognizedText.MatchKind, String?)] = [
            (.trackTitle, trackTitle),
            (.artistName, artistName),
            (.albumTitle, albumTitle)
        ]

        for (kind, target) in targets {
            guard let target,
                  let match = bestObservationMatch(for: target, kind: kind, observations: observations) else {
                continue
            }
            return match
        }
        return nil
    }

    static func sampledTextColor(
        in image: CGImage,
        boundingBox: CGRect,
        background: AlbumArtworkRGBColor,
        minimumContrast: CGFloat,
        requireScreenContrast: Bool = true
    ) -> AlbumArtworkRGBColor? {
        let rect = pixelRect(forNormalizedBoundingBox: boundingBox, image: image).insetBy(dx: -2, dy: -2)
        let palette = extractPalette(from: image, in: rect, maxColors: 6)
        guard !palette.isEmpty else { return nil }

        let surroundingPalette = extractPalette(from: image, in: surroundingRects(for: rect, image: image), maxColors: 4)
        let localBackground = surroundingPalette.first?.color ?? palette.first?.color ?? background

        var candidates = palette
            .filter { $0.color.distance(to: localBackground) > 0.14 || $0.color.contrastRatio(against: localBackground) > 1.45 }

        if requireScreenContrast {
            candidates = candidates.filter { $0.color.distance(to: background) > 0.16 }
        }

        return candidates
            .max { left, right in
                let leftScore = textSampleScore(
                    left,
                    localBackground: localBackground,
                    screenBackground: requireScreenContrast ? background : nil
                )
                let rightScore = textSampleScore(
                    right,
                    localBackground: localBackground,
                    screenBackground: requireScreenContrast ? background : nil
                )
                return leftScore < rightScore
            }?
            .color
    }

    static func theme(
        from palette: [AlbumArtworkPaletteColor],
        croppedImage: CGImage?,
        recognizedText: [AlbumArtworkRecognizedText],
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        options: Options
    ) -> AlbumArtworkTheme {
        let cleanedPalette = cleaned(palette)
        logPalette("builder cleaned palette", cleanedPalette)
        guard !cleanedPalette.isEmpty else {
            AlbumArtworkThemeDiagnostics.log("builder fallback: cleaned palette is empty")
            return .fallback
        }

        if isMonochrome(cleanedPalette) {
            AlbumArtworkThemeDiagnostics.log("builder path: monochrome")
            if let ocrTheme = monochromeOCRTheme(
                from: cleanedPalette,
                croppedImage: croppedImage,
                recognizedText: recognizedText,
                trackTitle: trackTitle,
                artistName: artistName,
                albumTitle: albumTitle,
                options: options
            ) {
                return ocrTheme
            }
            return monochromeTheme(from: cleanedPalette, options: options)
        }

        let backgroundCandidate = chooseBackgroundColor(from: cleanedPalette)
        let background = adjustBackground(backgroundCandidate)
        AlbumArtworkThemeDiagnostics.log(
            "builder background: candidate=\(AlbumArtworkThemeDiagnostics.describe(backgroundCandidate)) adjusted=\(AlbumArtworkThemeDiagnostics.describe(background))"
        )
        let accent = accentColor(from: cleanedPalette, avoiding: backgroundCandidate)
        let preferredForeground = preferredForeground(for: background, accent: accent)
        let textCandidates = textCandidates(from: cleanedPalette, background: background, avoiding: [backgroundCandidate])
        logPalette("builder text candidates", textCandidates)

        if let textAccent = ocrAccent(
            croppedImage: croppedImage,
            recognizedText: recognizedText,
            background: background,
            trackTitle: trackTitle,
            artistName: artistName,
            albumTitle: albumTitle,
            options: options
        ) {
            AlbumArtworkThemeDiagnostics.log(
                "builder ocr accent: color=\(AlbumArtworkThemeDiagnostics.describe(textAccent))"
            )
            let themeBackground = ocrBackground(
                from: cleanedPalette,
                raw: backgroundCandidate,
                adjusted: background,
                accent: textAccent,
                minimumContrast: options.titleMinimumContrast
            )
            return theme(
                background: themeBackground,
                titleAccent: textAccent,
                options: options,
                source: "ocr"
            )
        }

        if let paletteAccent = strongestForegroundAccent(
            from: textCandidates,
            background: background,
            avoiding: [backgroundCandidate]
        ) ?? accent {
            let themeBackground = preferredBackground(
                raw: backgroundCandidate,
                adjusted: background,
                accent: paletteAccent,
                minimumContrast: options.titleMinimumContrast
            )
            AlbumArtworkThemeDiagnostics.log(
                "builder palette accent: color=\(AlbumArtworkThemeDiagnostics.describe(paletteAccent))"
            )
            return theme(
                background: themeBackground,
                titleAccent: paletteAccent,
                fallbackTitleAccent: directlyReadablePaletteColor(
                    from: textCandidates,
                    against: themeBackground,
                    minimumContrast: options.titleMinimumContrast
                ),
                maximumTitleAdjustmentDistance: paletteAccentMaximumAdjustmentDistance,
                options: options,
                source: "palette-accent"
            )
        }

        let titleAccent = chooseReadableColor(
            from: textCandidates,
            against: background,
            minimumContrast: options.titleMinimumContrast,
            fallback: preferredForeground
        )
        let theme = theme(
            background: background,
            titleAccent: titleAccent,
            options: options,
            source: "palette"
        )
        AlbumArtworkThemeDiagnostics.log(
            "builder result fallback palette: background=\(AlbumArtworkThemeDiagnostics.describe(background)) title=\(AlbumArtworkThemeDiagnostics.describe(theme.trackTitleRGB)) titleContrast=\(AlbumArtworkThemeDiagnostics.format(theme.trackTitleRGB.contrastRatio(against: background))) artist=\(AlbumArtworkThemeDiagnostics.describe(theme.artistNameRGB)) artistContrast=\(AlbumArtworkThemeDiagnostics.format(theme.artistNameRGB.contrastRatio(against: background))) album=\(AlbumArtworkThemeDiagnostics.describe(theme.albumNameRGB)) albumContrast=\(AlbumArtworkThemeDiagnostics.format(theme.albumNameRGB.contrastRatio(against: background)))"
        )
        return theme
    }

    private static func downsampledImage(from data: Data, maxDimension: CGFloat) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    private static func cropped(_ image: CGImage, removingOuterPercent percent: CGFloat) -> CGImage? {
        let cropX = Int(CGFloat(image.width) * percent)
        let cropY = Int(CGFloat(image.height) * percent)
        let width = image.width - (cropX * 2)
        let height = image.height - (cropY * 2)
        guard width > 1, height > 1 else { return image }

        return image.cropping(to: CGRect(x: cropX, y: cropY, width: width, height: height))
    }

    private static func extractPalette(from image: CGImage, maxColors: Int) -> [AlbumArtworkPaletteColor] {
        extractPalette(
            from: image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height),
            maxColors: maxColors
        )
    }

    private static func extractPalette(from image: CGImage, in rect: CGRect, maxColors: Int) -> [AlbumArtworkPaletteColor] {
        extractPalette(from: image, in: [rect], maxColors: maxColors)
    }

    private static func extractPalette(from image: CGImage, in rects: [CGRect], maxColors: Int) -> [AlbumArtworkPaletteColor] {
        let width = image.width
        let height = image.height
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
            return []
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var buckets: [Int: (red: Int, green: Int, blue: Int, count: Int)] = [:]
        let step = max(1, Int(sqrt(CGFloat(width * height) / 4096)))
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        let sampleRects = rects
            .map { $0.intersection(imageRect).integral }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !sampleRects.isEmpty else { return [] }

        for sampleRect in sampleRects {
            let minX = max(0, Int(sampleRect.minX))
            let maxX = min(width, Int(sampleRect.maxX))
            let minY = max(0, Int(sampleRect.minY))
            let maxY = min(height, Int(sampleRect.maxY))

            for y in stride(from: minY, to: maxY, by: step) {
                for x in stride(from: minX, to: maxX, by: step) {
                    let index = (y * bytesPerRow) + (x * bytesPerPixel)
                    let alpha = pixels[index + 3]
                    guard alpha > 24 else { continue }

                    let red = Int(pixels[index])
                    let green = Int(pixels[index + 1])
                    let blue = Int(pixels[index + 2])
                    let key = ((red >> 3) << 10) | ((green >> 3) << 5) | (blue >> 3)
                    let current = buckets[key] ?? (0, 0, 0, 0)
                    buckets[key] = (
                        current.red + red,
                        current.green + green,
                        current.blue + blue,
                        current.count + 1
                    )
                }
            }
        }

        return buckets.values
            .map { bucket in
                AlbumArtworkPaletteColor(
                    color: AlbumArtworkRGBColor(
                        CGFloat(bucket.red) / CGFloat(bucket.count * 255),
                        CGFloat(bucket.green) / CGFloat(bucket.count * 255),
                        CGFloat(bucket.blue) / CGFloat(bucket.count * 255)
                    ),
                    population: bucket.count
                )
            }
            .sorted { $0.population > $1.population }
            .prefix(maxColors * 4)
            .reduce(into: [AlbumArtworkPaletteColor]()) { result, candidate in
                if let index = result.firstIndex(where: { $0.color.distance(to: candidate.color) < 0.10 }) {
                    let existing = result[index]
                    let totalPopulation = existing.population + candidate.population
                    let mergedColor = AlbumArtworkRGBColor(
                        ((existing.color.r * CGFloat(existing.population)) + (candidate.color.r * CGFloat(candidate.population))) / CGFloat(totalPopulation),
                        ((existing.color.g * CGFloat(existing.population)) + (candidate.color.g * CGFloat(candidate.population))) / CGFloat(totalPopulation),
                        ((existing.color.b * CGFloat(existing.population)) + (candidate.color.b * CGFloat(candidate.population))) / CGFloat(totalPopulation)
                    )
                    result[index] = AlbumArtworkPaletteColor(color: mergedColor, population: totalPopulation)
                } else if result.count < maxColors {
                    result.append(candidate)
                }
            }
            .sorted { $0.population > $1.population }
    }

    private static func recognizeText(in image: CGImage) -> [AlbumArtworkRecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.025

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AlbumArtworkThemeDiagnostics.log("builder ocr failed: \(error.localizedDescription)")
            return []
        }

        let observations = request.results?.compactMap { observation -> AlbumArtworkRecognizedText? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return AlbumArtworkRecognizedText(
                text: candidate.string,
                confidence: CGFloat(candidate.confidence),
                boundingBox: observation.boundingBox
            )
        } ?? []

        if !observations.isEmpty {
            let summary = observations
                .prefix(8)
                .map { "\($0.text)(\(AlbumArtworkThemeDiagnostics.format($0.confidence)))" }
                .joined(separator: " | ")
            AlbumArtworkThemeDiagnostics.log("builder ocr observations: \(summary)")
        }
        return observations
    }

    private static func cleaned(_ palette: [AlbumArtworkPaletteColor]) -> [AlbumArtworkPaletteColor] {
        palette
            .filter { $0.population > 0 }
            .sorted { $0.population > $1.population }
            .reduce(into: [AlbumArtworkPaletteColor]()) { result, candidate in
                if let index = result.firstIndex(where: { $0.color.distance(to: candidate.color) < 0.11 }) {
                    let existing = result[index]
                    result[index] = AlbumArtworkPaletteColor(
                        color: existing.population >= candidate.population ? existing.color : candidate.color,
                        population: existing.population + candidate.population
                    )
                } else {
                    result.append(candidate)
                }
            }
            .sorted { $0.population > $1.population }
    }

    private static func isMonochrome(_ palette: [AlbumArtworkPaletteColor]) -> Bool {
        monochromeAnalysis(for: palette).isMonochrome
    }

    private static func monochromeAnalysis(for palette: [AlbumArtworkPaletteColor]) -> AlbumArtworkThemeDebugMonochromeAnalysis {
        let totalPopulation = max(palette.reduce(0) { $0 + $1.population }, 1)
        let averageSaturation = palette.reduce(CGFloat.zero) {
            $0 + ($1.color.saturation * CGFloat($1.population))
        } / CGFloat(totalPopulation)
        let neutralPopulation = palette
            .filter { $0.color.isNeutral || $0.color.isNearBlack || $0.color.isNearWhite }
            .reduce(0) { $0 + $1.population }
        let chromaticPopulation = palette
            .filter { !$0.color.isNearWhite && !$0.color.isNearBlack && $0.color.saturation > 0.14 }
            .reduce(0) { $0 + $1.population }
        let neutralShare = CGFloat(neutralPopulation) / CGFloat(totalPopulation)
        let chromaticShare = CGFloat(chromaticPopulation) / CGFloat(totalPopulation)
        let result = chromaticShare < 0.10 && ((palette.count < 3 && averageSaturation < 0.20)
            || averageSaturation < 0.16
            || neutralShare > 0.82)

        AlbumArtworkThemeDiagnostics.log(
            "builder monochrome check: count=\(palette.count) avgSat=\(AlbumArtworkThemeDiagnostics.format(averageSaturation)) neutralShare=\(AlbumArtworkThemeDiagnostics.format(neutralShare)) chromaticShare=\(AlbumArtworkThemeDiagnostics.format(chromaticShare)) result=\(result)"
        )
        return AlbumArtworkThemeDebugMonochromeAnalysis(
            averageSaturation: averageSaturation,
            neutralShare: neutralShare,
            chromaticShare: chromaticShare,
            isMonochrome: result
        )
    }

    private static func monochromeTheme(
        from palette: [AlbumArtworkPaletteColor],
        options: Options
    ) -> AlbumArtworkTheme {
        let dominant = palette.max { $0.population < $1.population }?.color ?? .defaultPlayerBackground
        let background = monochromeBackground(from: palette)

        let accent = accentColor(from: palette) ?? dominant
        let textCandidates = textCandidates(from: palette, background: background)
        let preferredForeground = preferredForeground(for: background, accent: accent)
        let title = chooseReadableColor(
            from: textCandidates,
            against: background,
            minimumContrast: options.titleMinimumContrast,
            fallback: preferredForeground
        )
        let theme = theme(
            background: background,
            titleAccent: title,
            options: options,
            source: "monochrome"
        )
        AlbumArtworkThemeDiagnostics.log(
            "builder monochrome result: dominant=\(AlbumArtworkThemeDiagnostics.describe(dominant)) background=\(AlbumArtworkThemeDiagnostics.describe(background)) title=\(AlbumArtworkThemeDiagnostics.describe(theme.trackTitleRGB)) contrast=\(AlbumArtworkThemeDiagnostics.format(theme.trackTitleRGB.contrastRatio(against: background)))"
        )
        return theme
    }

    private static func monochromeOCRTheme(
        from palette: [AlbumArtworkPaletteColor],
        croppedImage: CGImage?,
        recognizedText: [AlbumArtworkRecognizedText],
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        options: Options
    ) -> AlbumArtworkTheme? {
        let provisionalBackground = monochromeBackground(from: palette)
        guard let textAccent = ocrAccent(
            croppedImage: croppedImage,
            recognizedText: recognizedText,
            background: provisionalBackground,
            trackTitle: trackTitle,
            artistName: artistName,
            albumTitle: albumTitle,
            options: options
        ) else {
            return nil
        }

        let background = monochromeBackground(
            from: palette,
            for: textAccent,
            minimumContrast: options.titleMinimumContrast
        )
        AlbumArtworkThemeDiagnostics.log(
            "builder monochrome ocr accent: background=\(AlbumArtworkThemeDiagnostics.describe(background)) color=\(AlbumArtworkThemeDiagnostics.describe(textAccent))"
        )
        return theme(
            background: background,
            titleAccent: textAccent,
            options: options,
            source: "ocr"
        )
    }

    private static func monochromeBackground(from palette: [AlbumArtworkPaletteColor]) -> AlbumArtworkRGBColor {
        let dominant = palette.max { $0.population < $1.population }?.color ?? .defaultPlayerBackground
        if dominant.relativeLuminance > 0.78 {
            return dominant.adjustedToward(.black, targetLuminance: 0.52, maxAmount: 0.36)
        }
        if dominant.relativeLuminance > 0.42 {
            return dominant.adjustedToward(.black, targetLuminance: 0.38, maxAmount: 0.20)
        }
        return dominant.relativeLuminance > 0.18
            ? dominant.adjustedToward(.black, targetLuminance: 0.14, maxAmount: 0.22)
            : dominant
    }

    private static func monochromeBackground(
        from palette: [AlbumArtworkPaletteColor],
        for accent: AlbumArtworkRGBColor,
        minimumContrast: CGFloat
    ) -> AlbumArtworkRGBColor {
        if let paletteBackground = palette
            .filter({ $0.color.distance(to: accent) > 0.16 })
            .filter({ $0.color.contrastRatio(against: accent) >= minimumContrast })
            .max(by: { left, right in
                let leftScore = monochromeBackgroundScore(left, accent: accent)
                let rightScore = monochromeBackgroundScore(right, accent: accent)
                return leftScore < rightScore
            })?
            .color {
            return paletteBackground
        }

        return backgroundPreservingAccent(
            monochromeBackground(from: palette),
            accent: accent,
            minimumContrast: minimumContrast,
            preserveAccent: true
        )
    }

    private static func monochromeBackgroundScore(
        _ entry: AlbumArtworkPaletteColor,
        accent: AlbumArtworkRGBColor
    ) -> CGFloat {
        let contrast = min(entry.color.contrastRatio(against: accent), 12) / 12
        let extremityPenalty: CGFloat = entry.color.isNearWhite || entry.color.isNearBlack ? 0.82 : 1
        return CGFloat(entry.population) * (0.8 + contrast) * extremityPenalty
    }

    private static func accentColor(
        from palette: [AlbumArtworkPaletteColor],
        avoiding avoidedColor: AlbumArtworkRGBColor? = nil
    ) -> AlbumArtworkRGBColor? {
        let filteredPalette = palette
            .filter { !$0.color.isNearWhite && !$0.color.isNearBlack && $0.color.saturation > 0.08 }
            .filter { entry in
                guard let avoidedColor else { return true }
                return entry.color.distance(to: avoidedColor) > 0.24
            }

        return (filteredPalette.isEmpty ? palette : filteredPalette)
            .filter { !$0.color.isNearWhite && !$0.color.isNearBlack && $0.color.saturation > 0.08 }
            .max { lhs, rhs in
                let lhsScore = CGFloat(lhs.population) * (0.6 + lhs.color.saturation)
                let rhsScore = CGFloat(rhs.population) * (0.6 + rhs.color.saturation)
                return lhsScore < rhsScore
            }?
            .color
    }

    private static func strongestForegroundAccent(
        from candidates: [AlbumArtworkPaletteColor],
        background: AlbumArtworkRGBColor,
        avoiding avoidedColors: [AlbumArtworkRGBColor] = []
    ) -> AlbumArtworkRGBColor? {
        candidates
            .filter { $0.color.distance(to: background) > 0.22 }
            .filter { entry in
                avoidedColors.allSatisfy { entry.color.distance(to: $0) > 0.24 }
            }
            .filter { !$0.color.isNearWhite && !$0.color.isNearBlack }
            .max { left, right in
                let leftScore = foregroundAccentScore(left, background: background)
                let rightScore = foregroundAccentScore(right, background: background)
                return leftScore < rightScore
            }?
            .color
    }

    private static func directlyReadablePaletteColor(
        from candidates: [AlbumArtworkPaletteColor],
        against background: AlbumArtworkRGBColor,
        minimumContrast: CGFloat
    ) -> AlbumArtworkRGBColor? {
        candidates.first { candidate in
            candidate.color.contrastRatio(against: background) >= minimumContrast
        }?.color
    }

    private static func foregroundAccentScore(
        _ entry: AlbumArtworkPaletteColor,
        background: AlbumArtworkRGBColor
    ) -> CGFloat {
        let chromaBoost: CGFloat = entry.color.isNeutral ? 0.45 : 1.25
        let contrast = min(entry.color.contrastRatio(against: background), 8) / 8
        return CGFloat(entry.population) * (0.7 + entry.color.saturation) * chromaBoost * (0.65 + contrast)
    }

    private static func textCandidates(
        from palette: [AlbumArtworkPaletteColor],
        background: AlbumArtworkRGBColor,
        avoiding avoidedColors: [AlbumArtworkRGBColor] = []
    ) -> [AlbumArtworkPaletteColor] {
        palette
            .filter { $0.color.distance(to: background) > 0.18 }
            .filter { entry in
                avoidedColors.allSatisfy { entry.color.distance(to: $0) > 0.24 }
            }
            .sorted { lhs, rhs in
                let lhsChromatic = isChromaticTextCandidate(lhs.color)
                let rhsChromatic = isChromaticTextCandidate(rhs.color)
                if lhsChromatic != rhsChromatic {
                    return lhsChromatic
                }
                if lhsChromatic && rhsChromatic && lhs.color.saturation != rhs.color.saturation {
                    return lhs.color.saturation > rhs.color.saturation
                }
                return lhs.population > rhs.population
            }
    }

    private static func isChromaticTextCandidate(_ color: AlbumArtworkRGBColor) -> Bool {
        !color.isNearWhite && !color.isNearBlack && !color.isNeutral
    }

    private static func chooseBackgroundColor(from palette: [AlbumArtworkPaletteColor]) -> AlbumArtworkRGBColor {
        let totalPopulation = max(palette.reduce(0) { $0 + $1.population }, 1)
        if let dominant = palette.first {
            let dominantShare = CGFloat(dominant.population) / CGFloat(totalPopulation)
            let darkInkShare = CGFloat(
                palette
                    .filter { $0.color.relativeLuminance < 0.08 }
                    .reduce(0) { $0 + $1.population }
            ) / CGFloat(totalPopulation)
            let lightGroundShare = CGFloat(
                palette
                    .filter { $0.color.relativeLuminance > 0.68 && $0.color.saturation < 0.14 }
                    .reduce(0) { $0 + $1.population }
            ) / CGFloat(totalPopulation)

            if dominant.color.relativeLuminance > 0.72,
               dominantShare > 0.36,
               lightGroundShare > 0.42,
               darkInkShare > 0.12 {
                return dominant.color
            }

            let vividAlternatives = palette
                .filter { $0.color.relativeLuminance > 0.06 }
                .filter { $0.color.relativeLuminance < 0.58 }
                .filter { $0.color.saturation > 0.44 }
                .filter { !$0.color.isNearWhite && !$0.color.isNearBlack }
            let vividShare = CGFloat(vividAlternatives.reduce(0) { $0 + $1.population }) / CGFloat(totalPopulation)

            if dominant.color.relativeLuminance < 0.08,
               dominant.color.saturation < 0.40,
               dominantShare < 0.86 || vividShare > 0.10,
               let vivid = vividAlternatives.max(by: { left, right in
                   let leftScore = CGFloat(left.population) * (0.65 + left.color.saturation)
                   let rightScore = CGFloat(right.population) * (0.65 + right.color.saturation)
                   return leftScore < rightScore
               }) {
                return vivid.color
            }
        }

        if let chromatic = palette
            .filter({ !$0.color.isNearWhite && !$0.color.isNearBlack && !$0.color.isNeutral })
            .max(by: { left, right in
                let leftScore = CGFloat(left.population) * (0.8 + left.color.saturation)
                let rightScore = CGFloat(right.population) * (0.8 + right.color.saturation)
                return leftScore < rightScore
            }) {
            return chromatic.color
        }

        return palette.first?.color ?? .defaultPlayerBackground
    }

    private static func adjustBackground(_ color: AlbumArtworkRGBColor) -> AlbumArtworkRGBColor {
        let luminance = color.relativeLuminance

        if luminance > 0.70 {
            return color.adjustedToward(.black, targetLuminance: 0.62, maxAmount: 0.16)
        }
        if luminance > 0.52 {
            return color.adjustedToward(.black, targetLuminance: 0.50, maxAmount: 0.10)
        }
        if luminance < 0.05, color.saturation > 0.24 {
            return color.adjustedToward(.white, targetLuminance: 0.10, maxAmount: 0.18)
        }
        return color
    }

    private static func preferredBackground(
        raw: AlbumArtworkRGBColor,
        adjusted: AlbumArtworkRGBColor,
        accent: AlbumArtworkRGBColor,
        minimumContrast: CGFloat
    ) -> AlbumArtworkRGBColor {
        if raw.relativeLuminance < adjusted.relativeLuminance,
           accent.contrastRatio(against: raw) >= minimumContrast {
            return raw
        }
        return adjusted
    }

    private static func ocrBackground(
        from palette: [AlbumArtworkPaletteColor],
        raw: AlbumArtworkRGBColor,
        adjusted: AlbumArtworkRGBColor,
        accent: AlbumArtworkRGBColor,
        minimumContrast: CGFloat
    ) -> AlbumArtworkRGBColor {
        if raw.contrastRatio(against: accent) >= minimumContrast {
            return raw
        }
        if adjusted.contrastRatio(against: accent) >= minimumContrast,
           adjusted.distance(to: raw) < 0.18 {
            return adjusted
        }

        if let paletteBackground = palette
            .filter({ $0.color.distance(to: accent) > 0.16 })
            .filter({ $0.color.contrastRatio(against: accent) >= minimumContrast })
            .max(by: { left, right in
                let leftScore = ocrBackgroundScore(left, accent: accent)
                let rightScore = ocrBackgroundScore(right, accent: accent)
                return leftScore < rightScore
            })?
            .color {
            return paletteBackground
        }

        if let nearReadablePaletteBackground = palette
            .filter({ $0.color.distance(to: accent) > 0.16 })
            .filter({
                adjustedForeground(
                    accent,
                    against: $0.color,
                    minimumContrast: minimumContrast
                ).distance(to: accent) <= 0.22
            })
            .max(by: { left, right in
                let leftScore = ocrBackgroundScore(left, accent: accent)
                let rightScore = ocrBackgroundScore(right, accent: accent)
                return leftScore < rightScore
            })?
            .color {
            return nearReadablePaletteBackground
        }

        return backgroundPreservingAccent(
            adjusted,
            accent: accent,
            minimumContrast: minimumContrast,
            preserveAccent: true
        )
    }

    private static func ocrBackgroundScore(
        _ entry: AlbumArtworkPaletteColor,
        accent: AlbumArtworkRGBColor
    ) -> CGFloat {
        let contrast = min(entry.color.contrastRatio(against: accent), 12) / 12
        let extremityPenalty: CGFloat = entry.color.isNearWhite || entry.color.isNearBlack ? 0.82 : 1
        return CGFloat(entry.population) * (0.9 + contrast) * extremityPenalty
    }

    private static func ocrAccent(
        croppedImage: CGImage?,
        recognizedText: [AlbumArtworkRecognizedText],
        background: AlbumArtworkRGBColor,
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        options: Options
    ) -> AlbumArtworkRGBColor? {
        guard let croppedImage,
              let match = bestTextMatch(
                  in: recognizedText,
                  trackTitle: trackTitle,
                  artistName: artistName,
                  albumTitle: albumTitle
              ) else {
            return nil
        }

        guard let sampled = sampledTextColor(
            in: croppedImage,
            boundingBox: match.observation.boundingBox,
            background: background,
            minimumContrast: options.titleMinimumContrast,
            requireScreenContrast: false
        ) else {
            AlbumArtworkThemeDiagnostics.log("builder ocr match without usable color: \(match.observation.text)")
            return nil
        }

        return sampled
    }

    private static func theme(
        background: AlbumArtworkRGBColor,
        titleAccent: AlbumArtworkRGBColor,
        fallbackTitleAccent: AlbumArtworkRGBColor? = nil,
        maximumTitleAdjustmentDistance: CGFloat? = nil,
        options: Options,
        source: String
    ) -> AlbumArtworkTheme {
        let titleAccent = resolvedTitleAccent(
            titleAccent,
            against: background,
            minimumContrast: options.titleMinimumContrast,
            fallback: fallbackTitleAccent,
            maximumAdjustmentDistance: maximumTitleAdjustmentDistance
        )
        let background = backgroundPreservingAccent(
            background,
            accent: titleAccent,
            minimumContrast: options.titleMinimumContrast,
            preserveAccent: source == "ocr"
        )
        let title = readableAccent(
            titleAccent,
            against: background,
            minimumContrast: options.titleMinimumContrast
        )
        let artistBase = title.hueShifted(0, saturationMultiplier: 0.92, brightnessMultiplier: 0.94)
        let artist = readableAccent(
            soften(artistBase, against: background, minimumContrast: options.detailMinimumContrast),
            against: background,
            minimumContrast: options.detailMinimumContrast
        )
        let albumBase = title.hueShifted(0, saturationMultiplier: 0.82, brightnessMultiplier: 0.88)
        let album = readableAccent(
            soften(albumBase, against: background, minimumContrast: options.detailMinimumContrast),
            against: background,
            minimumContrast: options.detailMinimumContrast
        )

        let theme = AlbumArtworkTheme(
            backgroundRGB: background,
            trackTitleRGB: title,
            artistNameRGB: artist,
            albumNameRGB: album,
            isFallback: false,
            source: themeSource(for: source)
        )
        AlbumArtworkThemeDiagnostics.log(
            "builder result source=\(source): background=\(AlbumArtworkThemeDiagnostics.describe(background)) title=\(AlbumArtworkThemeDiagnostics.describe(title)) titleContrast=\(AlbumArtworkThemeDiagnostics.format(title.contrastRatio(against: background))) artist=\(AlbumArtworkThemeDiagnostics.describe(artist)) artistContrast=\(AlbumArtworkThemeDiagnostics.format(artist.contrastRatio(against: background))) album=\(AlbumArtworkThemeDiagnostics.describe(album)) albumContrast=\(AlbumArtworkThemeDiagnostics.format(album.contrastRatio(against: background)))"
        )
        return theme
    }

    private static func backgroundPreservingAccent(
        _ background: AlbumArtworkRGBColor,
        accent: AlbumArtworkRGBColor,
        minimumContrast: CGFloat,
        preserveAccent: Bool = false
    ) -> AlbumArtworkRGBColor {
        guard accent.contrastRatio(against: background) < minimumContrast else {
            return background
        }

        let preferDarkerBackground = accent.relativeLuminance >= background.relativeLuminance
        let target = preferDarkerBackground ? AlbumArtworkRGBColor.black : .white
        let hasStrongColourPair = background.saturation > 0.45 && accent.saturation > 0.45
        let maxAmount: CGFloat
        if preserveAccent {
            maxAmount = 0.62
        } else if hasStrongColourPair {
            maxAmount = 0.36
        } else if background.relativeLuminance > 0.32 {
            maxAmount = 0.22
        } else {
            maxAmount = 0.16
        }
        var best = background
        for step in 1...16 {
            let amount = CGFloat(step) / 16 * maxAmount
            let candidate = background.mixed(with: target, amount: amount)
            if accent.contrastRatio(against: candidate) >= minimumContrast {
                return candidate
            }
            if accent.contrastRatio(against: candidate) > accent.contrastRatio(against: best) {
                best = candidate
            }
        }
        return best
    }

    private static func themeSource(for source: String) -> AlbumArtworkThemeSource {
        switch source {
        case "ocr":
            return .ocr
        case "monochrome":
            return .monochrome
        case "palette":
            return .palette
        default:
            return .paletteAccent
        }
    }

    private static func readableAccent(
        _ accent: AlbumArtworkRGBColor,
        against background: AlbumArtworkRGBColor,
        minimumContrast: CGFloat
    ) -> AlbumArtworkRGBColor {
        if accent.contrastRatio(against: background) >= minimumContrast {
            return accent
        }
        return adjustedForeground(accent, against: background, minimumContrast: minimumContrast)
    }

    private static func resolvedTitleAccent(
        _ accent: AlbumArtworkRGBColor,
        against background: AlbumArtworkRGBColor,
        minimumContrast: CGFloat,
        fallback: AlbumArtworkRGBColor?,
        maximumAdjustmentDistance: CGFloat?
    ) -> AlbumArtworkRGBColor {
        guard accent.contrastRatio(against: background) < minimumContrast,
              let maximumAdjustmentDistance else {
            return accent
        }

        let adjusted = adjustedForeground(accent, against: background, minimumContrast: minimumContrast)
        guard adjusted.distance(to: accent) > maximumAdjustmentDistance else {
            return accent
        }

        if let fallback,
           fallback.contrastRatio(against: background) >= minimumContrast {
            return fallback
        }
        return accent
    }

    private static func chooseReadableColor(
        from candidates: [AlbumArtworkPaletteColor],
        against background: AlbumArtworkRGBColor,
        minimumContrast: CGFloat,
        fallback: AlbumArtworkRGBColor
    ) -> AlbumArtworkRGBColor {
        for candidate in candidates {
            if candidate.color.contrastRatio(against: background) >= minimumContrast {
                AlbumArtworkThemeDiagnostics.log(
                    "builder readable: direct color=\(AlbumArtworkThemeDiagnostics.describe(candidate.color)) contrast=\(AlbumArtworkThemeDiagnostics.format(candidate.color.contrastRatio(against: background))) minimum=\(AlbumArtworkThemeDiagnostics.format(minimumContrast))"
                )
                return candidate.color
            }

            let adjusted = adjustedForeground(candidate.color, against: background, minimumContrast: minimumContrast)
            if adjusted.contrastRatio(against: background) >= minimumContrast {
                AlbumArtworkThemeDiagnostics.log(
                    "builder readable: adjusted source=\(AlbumArtworkThemeDiagnostics.describe(candidate.color)) adjusted=\(AlbumArtworkThemeDiagnostics.describe(adjusted)) contrast=\(AlbumArtworkThemeDiagnostics.format(adjusted.contrastRatio(against: background))) minimum=\(AlbumArtworkThemeDiagnostics.format(minimumContrast))"
                )
                return adjusted
            }
        }

        if fallback.contrastRatio(against: background) >= minimumContrast {
            AlbumArtworkThemeDiagnostics.log(
                "builder readable: fallback=\(AlbumArtworkThemeDiagnostics.describe(fallback)) contrast=\(AlbumArtworkThemeDiagnostics.format(fallback.contrastRatio(against: background))) minimum=\(AlbumArtworkThemeDiagnostics.format(minimumContrast))"
            )
            return fallback
        }

        let preferredForeground = preferredForeground(for: background)
        AlbumArtworkThemeDiagnostics.log(
            "builder readable: preferred foreground=\(AlbumArtworkThemeDiagnostics.describe(preferredForeground)) contrast=\(AlbumArtworkThemeDiagnostics.format(preferredForeground.contrastRatio(against: background))) minimum=\(AlbumArtworkThemeDiagnostics.format(minimumContrast))"
        )
        return preferredForeground
    }

    private static func prefersLightForeground(for background: AlbumArtworkRGBColor) -> Bool {
        AlbumArtworkRGBColor.white.contrastRatio(against: background)
            >= AlbumArtworkRGBColor.black.contrastRatio(against: background)
    }

    private static func adjustedForeground(
        _ color: AlbumArtworkRGBColor,
        against background: AlbumArtworkRGBColor,
        minimumContrast: CGFloat
    ) -> AlbumArtworkRGBColor {
        let preferLight = prefersLightForeground(for: background)
        let target = preferLight ? AlbumArtworkRGBColor.white : .black
        let requiredLuminance = requiredForegroundLuminance(
            for: background,
            minimumContrast: minimumContrast,
            preferLight: preferLight
        )

        if preferLight {
            if color.relativeLuminance < requiredLuminance {
                let lightened = color.adjustedToward(.white, targetLuminance: requiredLuminance, maxAmount: 1)
                if lightened.contrastRatio(against: background) >= minimumContrast {
                    return lightened
                }
            }
        } else if color.relativeLuminance > requiredLuminance {
            let darkened = color.adjustedToward(.black, targetLuminance: requiredLuminance, maxAmount: 1)
            if darkened.contrastRatio(against: background) >= minimumContrast {
                return darkened
            }
        }

        var low: CGFloat = 0
        var high: CGFloat = 1
        var best = color.mixed(with: target, amount: 1)
        for _ in 0..<14 {
            let mid = (low + high) / 2
            let candidate = color.mixed(with: target, amount: mid)
            if candidate.contrastRatio(against: background) >= minimumContrast {
                best = candidate
                high = mid
            } else {
                low = mid
            }
        }
        return best
    }

    private static func requiredForegroundLuminance(
        for background: AlbumArtworkRGBColor,
        minimumContrast: CGFloat,
        preferLight: Bool
    ) -> CGFloat {
        let backgroundLuminance = background.relativeLuminance
        if preferLight {
            return min(0.98, (backgroundLuminance + 0.05) * minimumContrast - 0.05)
        }
        return max(0.02, (backgroundLuminance + 0.05) / minimumContrast - 0.05)
    }

    private static func preferredForeground(
        for background: AlbumArtworkRGBColor,
        accent: AlbumArtworkRGBColor? = nil
    ) -> AlbumArtworkRGBColor {
        let preferLight = prefersLightForeground(for: background)
        let base = preferLight ? AlbumArtworkRGBColor.white : .black
        guard let accent, accent.saturation > 0.08 else { return base }

        let requiredLuminance = requiredForegroundLuminance(
            for: background,
            minimumContrast: 4.5,
            preferLight: preferLight
        )
        let target = preferLight ? AlbumArtworkRGBColor.white : .black
        let tinted = accent.adjustedToward(target, targetLuminance: requiredLuminance, maxAmount: 1)
        if tinted.contrastRatio(against: background) >= 4.5 {
            return tinted
        }

        let subtleTint = base.mixed(with: accent, amount: 0.18)
        if subtleTint.contrastRatio(against: background) >= 4.5 {
            return subtleTint
        }
        return base
    }

    private static func bestObservationMatch(
        for target: String,
        kind: AlbumArtworkRecognizedText.MatchKind,
        observations: [AlbumArtworkRecognizedText]
    ) -> AlbumArtworkTextMatch? {
        let normalizedTarget = normalizedText(target)
        guard !normalizedTarget.isEmpty else { return nil }
        let targetTokens = normalizedTarget.split(separator: " ").map(String.init)
        let isShortTarget = normalizedTarget.count <= 4 || (targetTokens.count == 1 && (targetTokens.first?.count ?? 0) <= 4)
        let matchCandidates = isShortTarget
            ? observations
            : observations + combinedObservationCandidates(from: observations)

        let scored = matchCandidates.compactMap { observation -> (AlbumArtworkRecognizedText, CGFloat)? in
            guard observation.confidence >= 0.35 else { return nil }
            let normalizedObservation = normalizedText(observation.text)
            guard !normalizedObservation.isEmpty else { return nil }
            let observationTokens = Set(normalizedObservation.split(separator: " ").map(String.init))

            if isShortTarget {
                guard observationTokens.contains(normalizedTarget) || normalizedObservation == normalizedTarget else {
                    return nil
                }
                return (observation, observation.confidence + 2)
            }

            if normalizedObservation == normalizedTarget {
                return (observation, observation.confidence + 4)
            }

            if normalizedObservation.contains(normalizedTarget) {
                return (observation, observation.confidence + 1)
            }

            let matchingTokens = targetTokens.filter { observationTokens.contains($0) }.count
            let coverage = CGFloat(matchingTokens) / CGFloat(max(targetTokens.count, 1))
            guard targetTokens.count >= 2, coverage >= 0.75, observation.confidence >= 0.45 else {
                return nil
            }
            return (observation, observation.confidence + coverage)
        }

        return scored
            .max { left, right in left.1 < right.1 }
            .map { AlbumArtworkTextMatch(kind: kind, observation: $0.0) }
    }

    private static func combinedObservationCandidates(
        from observations: [AlbumArtworkRecognizedText]
    ) -> [AlbumArtworkRecognizedText] {
        let ordered = observations
            .filter { $0.confidence >= 0.35 && !normalizedText($0.text).isEmpty }
            .sorted { lhs, rhs in
                let rowDelta = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
                if rowDelta > 0.08 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
        guard ordered.count >= 2 else { return [] }

        var combined: [AlbumArtworkRecognizedText] = []
        let maxWindowSize = min(4, ordered.count)
        for startIndex in ordered.indices {
            for windowSize in 2...maxWindowSize {
                let endIndex = startIndex + windowSize
                guard endIndex <= ordered.count else { continue }
                let window = Array(ordered[startIndex..<endIndex])
                let text = window.map(\.text).joined(separator: " ")
                let confidence = window.map(\.confidence).reduce(0, +) / CGFloat(window.count)
                let boundingBox = window
                    .map(\.boundingBox)
                    .dropFirst()
                    .reduce(window[0].boundingBox) { partialResult, rect in
                        partialResult.union(rect)
                    }
                combined.append(AlbumArtworkRecognizedText(
                    text: text,
                    confidence: confidence,
                    boundingBox: boundingBox
                ))
            }
        }

        return combined
    }

    private static func pixelRect(forNormalizedBoundingBox boundingBox: CGRect, image: CGImage) -> CGRect {
        CGRect(
            x: boundingBox.minX * CGFloat(image.width),
            y: (1 - boundingBox.maxY) * CGFloat(image.height),
            width: boundingBox.width * CGFloat(image.width),
            height: boundingBox.height * CGFloat(image.height)
        )
    }

    private static func surroundingRects(for rect: CGRect, image: CGImage) -> [CGRect] {
        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let inner = rect.intersection(imageRect).integral
        guard !inner.isNull, inner.width > 0, inner.height > 0 else { return [] }

        let xInset = -max(6, inner.width * 0.22)
        let yInset = -max(6, inner.height * 0.45)
        let outer = inner
            .insetBy(dx: xInset, dy: yInset)
            .intersection(imageRect)
            .integral
        guard !outer.isNull, outer.width > 0, outer.height > 0 else { return [] }

        return [
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: max(0, inner.minY - outer.minY)),
            CGRect(x: outer.minX, y: inner.maxY, width: outer.width, height: max(0, outer.maxY - inner.maxY)),
            CGRect(x: outer.minX, y: inner.minY, width: max(0, inner.minX - outer.minX), height: inner.height),
            CGRect(x: inner.maxX, y: inner.minY, width: max(0, outer.maxX - inner.maxX), height: inner.height)
        ]
    }

    private static func textSampleScore(
        _ entry: AlbumArtworkPaletteColor,
        localBackground: AlbumArtworkRGBColor,
        screenBackground: AlbumArtworkRGBColor?
    ) -> CGFloat {
        let localContrast = min(entry.color.contrastRatio(against: localBackground), 8) / 8
        let populationScore = sqrt(CGFloat(entry.population))
        let localScore = populationScore * (0.45 + (localContrast * 1.6))
        guard let screenBackground else {
            return localScore
        }
        let screenContrast = min(entry.color.contrastRatio(against: screenBackground), 8) / 8
        return localScore * (0.55 + screenContrast)
    }

    private static func soften(
        _ color: AlbumArtworkRGBColor,
        against background: AlbumArtworkRGBColor,
        minimumContrast: CGFloat
    ) -> AlbumArtworkRGBColor {
        let softened = color.mixed(with: background, amount: 0.16)
        if softened.contrastRatio(against: background) >= minimumContrast {
            return softened
        }
        return color
    }

    private static func logPalette(_ label: String, _ palette: [AlbumArtworkPaletteColor]) {
        let summary = palette
            .prefix(10)
            .map { entry in
                "\(entry.population):\(AlbumArtworkThemeDiagnostics.describe(entry.color))"
            }
            .joined(separator: " | ")
        AlbumArtworkThemeDiagnostics.log("\(label): count=\(palette.count) \(summary)")
    }

    private static func debugTargets(
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?
    ) -> [AlbumArtworkThemeDebugTarget] {
        [
            ("Track title", trackTitle),
            ("Artist", artistName),
            ("Album", albumTitle)
        ].map { label, value in
            AlbumArtworkThemeDebugTarget(
                label: label,
                original: value,
                normalized: value.map(normalizedText) ?? ""
            )
        }
    }

    private static func debugPalette(_ palette: [AlbumArtworkPaletteColor]) -> [AlbumArtworkThemeDebugPaletteEntry] {
        palette.map { AlbumArtworkThemeDebugPaletteEntry(color: $0.color, population: $0.population) }
    }

    private static func debugOCR(
        croppedImage: CGImage?,
        recognizedText: [AlbumArtworkRecognizedText],
        background: AlbumArtworkRGBColor,
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        options: Options
    ) -> AlbumArtworkThemeDebugOCR {
        guard let match = bestTextMatch(
            in: recognizedText,
            trackTitle: trackTitle,
            artistName: artistName,
            albumTitle: albumTitle
        ) else {
            return AlbumArtworkThemeDebugOCR(
                observations: recognizedText,
                matchedKind: nil,
                matchedText: nil,
                matchedConfidence: nil,
                sampledTextColor: nil,
                localBackgroundColor: nil,
                localPalette: [],
                status: recognizedText.isEmpty
                    ? "Vision OCR returned no text observations."
                    : "Vision OCR found text, but none matched track, artist, or album metadata."
            )
        }

        guard let croppedImage else {
            return AlbumArtworkThemeDebugOCR(
                observations: recognizedText,
                matchedKind: match.kind,
                matchedText: match.observation.text,
                matchedConfidence: match.observation.confidence,
                sampledTextColor: nil,
                localBackgroundColor: nil,
                localPalette: [],
                status: "OCR matched \(match.kind.debugLabel), but no cropped image was available for colour sampling."
            )
        }

        let rect = pixelRect(forNormalizedBoundingBox: match.observation.boundingBox, image: croppedImage)
            .insetBy(dx: -2, dy: -2)
        let localPalette = extractPalette(from: croppedImage, in: rect, maxColors: 6)
        let surroundingPalette = extractPalette(from: croppedImage, in: surroundingRects(for: rect, image: croppedImage), maxColors: 4)
        let localBackground = surroundingPalette.first?.color ?? localPalette.first?.color
        let sampled = sampledTextColor(
            in: croppedImage,
            boundingBox: match.observation.boundingBox,
            background: background,
            minimumContrast: options.titleMinimumContrast,
            requireScreenContrast: false
        )
        let suffix = sampled.map {
            " Sampled glyph/accent colour \($0.debugDescription)."
        } ?? " No usable glyph colour survived local-background contrast filtering."

        return AlbumArtworkThemeDebugOCR(
            observations: recognizedText,
            matchedKind: match.kind,
            matchedText: match.observation.text,
            matchedConfidence: match.observation.confidence,
            sampledTextColor: sampled,
            localBackgroundColor: localBackground,
            localPalette: debugPalette(localPalette),
            status: "OCR matched \(match.kind.debugLabel)." + suffix
        )
    }

    private static func debugColorSummary(_ color: AlbumArtworkRGBColor) -> String {
        color.debugDescription
    }
}

private extension AlbumArtworkRGBColor {
    nonisolated var debugDescription: String {
        let red = Int((r * 255).rounded())
        let green = Int((g * 255).rounded())
        let blue = Int((b * 255).rounded())
        return "rgb(\(red),\(green),\(blue)), luminance \(AlbumArtworkThemeDiagnostics.format(relativeLuminance)), saturation \(AlbumArtworkThemeDiagnostics.format(saturation))"
    }
}
