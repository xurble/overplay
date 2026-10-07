import SwiftData
import SwiftUI

struct NowPlayingArtworkView: View {
    var urlString: String?
    var playlistID: String?
    var cornerRadius: CGFloat = 18
    var pixelSize: Int = 512

    var body: some View {
        ArtworkView(
            urlString: urlString,
            pixelSize: pixelSize,
            playlistID: playlistID,
            cornerRadius: cornerRadius
        )
    }
}

struct NowPlayingTrackTextView: View {
    var presentation: NowPlayingPresentation
    var titleFont: Font = .title.bold()
    var artistFont: Font = .title3
    var titleLineLimit: Int? = nil
    var detailLineLimit: Int? = nil
    var artworkTheme: AlbumArtworkTheme?

    var body: some View {
        VStack(spacing: 8) {
            Text(presentation.title)
                .font(titleFont)
                .playerLegibleForeground(artworkTheme?.trackTitleRGB, fallback: artworkTheme?.trackTitle ?? .primary)
                .multilineTextAlignment(.center)
                .lineLimit(titleLineLimit)
                .minimumScaleFactor(0.78)

            Text(presentation.artistName)
                .font(artistFont)
                .playerLegibleForeground(artworkTheme?.artistNameRGB, fallback: artworkTheme?.artistName ?? .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(detailLineLimit)
                .minimumScaleFactor(0.82)

            if let albumTitle = presentation.albumTitle {
                albumTitleText(albumTitle)
            }
        }
    }

    @ViewBuilder
    private func albumTitleText(_ albumTitle: String) -> some View {
        if let artworkTheme {
            Text(albumTitle)
                .font(.subheadline)
                .playerLegibleForeground(artworkTheme.albumNameRGB, fallback: artworkTheme.albumName)
                .multilineTextAlignment(.center)
                .lineLimit(detailLineLimit)
                .minimumScaleFactor(0.82)
        } else {
            Text(albumTitle)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(detailLineLimit)
                .minimumScaleFactor(0.82)
        }
    }
}

struct NowPlayingProgressView: View {
    var presentation: NowPlayingPresentation
    var foreground: Color? = nil
    var foregroundRGB: AlbumArtworkRGBColor? = nil

    var body: some View {
        VStack(spacing: 6) {
            NowPlayingProgressBar(
                progress: presentation.progress,
                phase: presentation.progressPhase,
                durationSeconds: presentation.durationSeconds,
                isPlaying: presentation.isPlaying,
                trackID: presentation.trackID
            )

            HStack {
                Text(presentation.elapsedText)
                    .playerLegibleForeground(foregroundRGB, fallback: foreground ?? .secondary)
                Spacer()
                Text(presentation.durationText)
                    .playerLegibleForeground(foregroundRGB, fallback: foreground ?? .secondary)
            }
            .font(.caption.monospacedDigit())
        }
    }
}

private struct NowPlayingProgressBar: View {
    var progress: Double
    var phase: NowPlayingProgressPhase
    var durationSeconds: Double?
    var isPlaying: Bool
    var trackID: String?

    @State private var sampledProgress = 0.0
    @State private var sampleDate = Date()
    @State private var sampledTrackID: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldInterpolateProgress)) { timeline in
            GeometryReader { proxy in
                let clampedProgress = displayedProgress(at: timeline.date)
                let innerWidth = max(proxy.size.width - 4, 0)
                let fillWidth = max(innerWidth * clampedProgress, clampedProgress > 0 ? 6 : 0)

                ZStack(alignment: .leading) {
                    // The same clear glass as an unpushed button, no outline.
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.clear, in: Capsule())

                    Capsule()
                        .fill(fillColor)
                        .overlay {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.24),
                                            .clear
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                        .frame(width: fillWidth)
                        .padding(2)
                        .animation(.smooth(duration: 0.45), value: phase)
                }
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int(displayedProgress(at: Date()) * 100)) percent")
        .onAppear {
            sampleCurrentProgress()
        }
        .onChange(of: progress) {
            sampleCurrentProgress()
        }
        .onChange(of: trackID) {
            sampleCurrentProgress()
        }
        .onChange(of: isPlaying) {
            sampleCurrentProgress()
        }
    }

    private var shouldInterpolateProgress: Bool {
        guard isPlaying, let durationSeconds, durationSeconds > 0 else {
            return false
        }
        return progress < 1
    }

    private func displayedProgress(at date: Date) -> Double {
        let baseProgress = sampledTrackID == trackID ? sampledProgress : clamped(progress)
        guard shouldInterpolateProgress, let durationSeconds else {
            return clamped(progress)
        }

        let elapsedSinceSample = max(date.timeIntervalSince(sampleDate), 0)
        return clamped(baseProgress + elapsedSinceSample / durationSeconds)
    }

    private func sampleCurrentProgress() {
        sampledProgress = clamped(progress)
        sampleDate = Date()
        sampledTrackID = trackID
    }

    private func clamped(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    private var fillColor: Color {
        switch phase {
        case .normal:
            Color(red: 0.62, green: 0.64, blue: 0.68)
        case .danger:
            Color(red: 0.96, green: 0.12, blue: 0.16)
        case .safe:
            Color(red: 0.10, green: 0.72, blue: 0.30)
        }
    }
}

struct TrackPlaybackFactsView: View {
    var presentation: NowPlayingPresentation
    var artworkTheme: AlbumArtworkTheme? = nil

    var body: some View {
        HStack(spacing: 14) {
            Label(presentation.playSkipMetricText, systemImage: "waveform.path.ecg")
                .help("Plays: Overplay / Apple Music")
                .accessibilityLabel(PlayCountPresentation.accessibilityLabel(
                    overplay: presentation.playthroughCount, apple: presentation.applePlayCount, skips: presentation.skipCount
                ))

            if presentation.isEvicted {
                let badge = TrackStateBadgePresentation(isEvicted: true)
                Label(badge.title, systemImage: badge.systemImage)
                    .foregroundStyle(.red)
            }
        }
        .font(.subheadline.weight(.semibold))
        // Plain text, not a capsule: it is not a button.
        .playerLegibleForeground(
            controlPalette?.foregroundRGB,
            fallback: controlPalette?.foreground ?? .primary,
            isActive: controlPalette != nil
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var controlPalette: FullScreenPlayerControlPalette? {
        artworkTheme.flatMap(FullScreenPlayerControlPalette.init(theme:))
    }
}

struct PlaybackModeControlsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var artworkTheme: AlbumArtworkTheme? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await playbackController.toggleShuffle(context: modelContext)
                }
            } label: {
                Label(controlsPresentation.shuffleTitle, systemImage: controlsPresentation.shuffleSystemImage)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityValue(controlsPresentation.isShuffling ? "On" : "Off")
            .fullScreenPlayerControlStyle(
                palette: controlPalette,
                prominence: controlsPresentation.isShuffling ? .selected : .secondary,
                fallbackTint: controlsPresentation.isShuffling ? .accentColor : .secondary,
                fallbackStyle: controlsPresentation.isShuffling ? .borderedProminent : .bordered
            )

            Button {
                Task {
                    await playbackController.toggleRepeatAll(context: modelContext)
                }
            } label: {
                Label(
                    controlsPresentation.repeatAllTitle,
                    systemImage: controlsPresentation.repeatAllSystemImage
                )
                .frame(maxWidth: .infinity)
            }
            .accessibilityValue(controlsPresentation.isRepeatingAll ? "On" : "Off")
            .fullScreenPlayerControlStyle(
                palette: controlPalette,
                prominence: controlsPresentation.isRepeatingAll ? .selected : .secondary,
                fallbackTint: controlsPresentation.isRepeatingAll ? .accentColor : .secondary,
                fallbackStyle: controlsPresentation.isRepeatingAll ? .borderedProminent : .bordered
            )
        }
        .disabled(!playbackController.hasLiveQueue)
    }

    private var controlPalette: FullScreenPlayerControlPalette? {
        artworkTheme.flatMap(FullScreenPlayerControlPalette.init(theme:))
    }

    private var controlsPresentation: PlaybackControlsPresentation {
        NowPlayingPresentationFactory.playbackControlsPresentation(playbackController: playbackController)
    }
}

struct TrackActionControlsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    var settings: OverplaySettings
    var artworkTheme: AlbumArtworkTheme? = nil

    var body: some View {
        HStack(spacing: 12) {
            if isCurrentTrackRetired {
                Button {
                    Task { playbackController.restoreCurrent(context: modelContext) }
                } label: {
                    Label("Triage", systemImage: "tray.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(playbackController.currentMember == nil)
                .fullScreenPlayerControlStyle(
                    palette: controlPalette,
                    prominence: .secondary,
                    fallbackStyle: .bordered
                )
                Button {
                    Task { await playbackController.promoteCurrent(settings: settings, context: modelContext) }
                } label: {
                    Label("Overplay", systemImage: "arrow.up.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(playbackController.currentMember == nil)
                .fullScreenPlayerControlStyle(
                    palette: controlPalette, prominence: .secondary, fallbackStyle: .bordered
                )
            } else {
                if currentPlaylistRole == .triageBucket {
                    Button {
                        Task { await playbackController.promoteCurrent(settings: settings, context: modelContext) }
                    } label: {
                        Label("Overplay", systemImage: "arrow.up.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(playbackController.currentMember == nil)
                    .fullScreenPlayerControlStyle(
                        palette: controlPalette,
                        prominence: .secondary,
                        fallbackStyle: .bordered
                    )
                }

                Button {
                    Task { await playbackController.evictCurrent(settings: settings, context: modelContext) }
                } label: {
                    Label("Retire", systemImage: "archivebox.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(playbackController.currentMember == nil)
                .fullScreenPlayerControlStyle(
                    palette: controlPalette,
                    prominence: .destructive,
                    fallbackStyle: .bordered
                )
            }
        }
    }

    private var controlPalette: FullScreenPlayerControlPalette? {
        artworkTheme.flatMap(FullScreenPlayerControlPalette.init(theme:))
    }

    private var currentPlaylistRole: PlaylistRole? {
        playbackController.currentPlaylistRole(context: modelContext)
    }

    private var isCurrentTrackRetired: Bool {
        playbackController.displayedIsEvicted(context: modelContext)
    }
}

/// Button colours from an artwork theme. A pushed (selected) button is filled
/// with the accent and its text is always the background colour. Every other
/// button is a tonal surface, the background tinted toward the accent, and
/// its text is the accent, never the background colour. Both pairs keep the
/// same minimum contrast, with a margin for the Liquid Glass drawn over the
/// fill, whose specular highlight follows the device's motion.
struct FullScreenPlayerControlPalette: Equatable {
    static let minimumContrast: CGFloat = 4.5
    /// Screen white and black. The theme's named colours stop short of them.
    static let white = AlbumArtworkRGBColor(1, 1, 1)
    static let black = AlbumArtworkRGBColor(0, 0, 0)

    let backgroundRGB: AlbumArtworkRGBColor
    /// The track title colour, moved away from the background only when it
    /// would otherwise miss the minimum contrast.
    let accentRGB: AlbumArtworkRGBColor
    /// Unpushed fill.
    let surfaceRGB: AlbumArtworkRGBColor
    /// False when no accent keeps the contrast margin under glass, as on a
    /// mid-grey background: buttons then show the exact fill without glass.
    let usesGlass: Bool

    init?(theme: AlbumArtworkTheme?) {
        guard let theme, !theme.isFallback else { return nil }
        let background = theme.backgroundRGB
        let isLight = background.relativeLuminance > 0.34
        let glassAccent = Self.accent(
            theme.trackTitleRGB, against: background,
            surfaceSheen: Self.glassLightening(isLight: isLight), pushedSheen: Self.pushedGlassLightening
        )
        let accent = glassAccent ?? Self.accent(theme.trackTitleRGB, against: background, surfaceSheen: 0, pushedSheen: 0)
            ?? Self.bestExtreme(against: background)
        let surfaceSheen = glassAccent == nil ? 0 : Self.glassLightening(isLight: isLight)

        usesGlass = glassAccent != nil
        backgroundRGB = background
        accentRGB = accent
        surfaceRGB = Self.tonalSurface(
            background, accent: accent, preferredTint: isLight ? 0.14 : 0.20, sheen: surfaceSheen
        )
    }

    /// Margin for the glass lightening an unpushed fill under its label,
    /// modelled as a mix toward white.
    static func glassLightening(isLight: Bool) -> CGFloat {
        isLight ? 0.03 : 0.08
    }

    /// The same margin for the pushed fill.
    static let pushedGlassLightening: CGFloat = 0.08

    /// Text on unpushed buttons and other themed surfaces.
    var foregroundRGB: AlbumArtworkRGBColor { accentRGB }
    var foreground: Color { accentRGB.color }

    var disabledForeground: Color {
        accentRGB.mixed(with: surfaceRGB, amount: 0.44).color
    }

    /// Text on pushed buttons: always the background colour.
    var selectedForegroundRGB: AlbumArtworkRGBColor { backgroundRGB }
    var selectedForeground: Color { backgroundRGB.color }

    var tint: Color {
        accentRGB.color
    }

    /// The glass over the art for a prominence, for text that adapts to it.
    func glassTint(for prominence: FullScreenPlayerControlProminence) -> PlayerGlassTint {
        prominence == .selected
            ? PlayerGlassTint(colour: accentRGB, opacity: 0.5)
            : PlayerGlassTint(colour: surfaceRGB, opacity: 0)
    }

    var surface: Color {
        surfaceRGB.color
    }

    var isLightBackground: Bool {
        backgroundRGB.relativeLuminance > 0.34
    }

    var shadowOpacity: Double {
        isLightBackground ? 0.14 : 0.34
    }

    /// Readable on the background, and on the background under the glass
    /// margin, so an untinted surface always passes; and readable under the
    /// background colour when it is the pushed fill under glass. Moves toward
    /// black or white, the further from the background first, never to it.
    /// Nil when no colour meets those margins.
    private static func accent(
        _ preferred: AlbumArtworkRGBColor,
        against background: AlbumArtworkRGBColor,
        surfaceSheen: CGFloat,
        pushedSheen: CGFloat
    ) -> AlbumArtworkRGBColor? {
        let sheened = background.mixed(with: white, amount: surfaceSheen)
        func worstContrast(_ color: AlbumArtworkRGBColor) -> CGFloat {
            min(
                color.contrastRatio(against: background),
                color.contrastRatio(against: sheened),
                background.contrastRatio(against: color.mixed(with: white, amount: pushedSheen))
            )
        }
        let extremes = [white, black].sorted { $0.contrastRatio(against: background) > $1.contrastRatio(against: background) }
        for extreme in extremes {
            for step in 0...10 {
                let candidate = preferred.mixed(with: extreme, amount: CGFloat(step) / 10)
                if worstContrast(candidate) >= minimumContrast { return candidate }
            }
        }
        return nil
    }

    private static func bestExtreme(against background: AlbumArtworkRGBColor) -> AlbumArtworkRGBColor {
        white.contrastRatio(against: background) >= black.contrastRatio(against: background) ? white : black
    }

    /// The background tinted toward the accent, as far as the accent text
    /// stays readable on it with and without the sheen.
    private static func tonalSurface(
        _ background: AlbumArtworkRGBColor,
        accent: AlbumArtworkRGBColor,
        preferredTint: CGFloat,
        sheen: CGFloat
    ) -> AlbumArtworkRGBColor {
        for step in stride(from: 4, through: 0, by: -1) {
            let surface = background.mixed(with: accent, amount: preferredTint * CGFloat(step) / 4)
            if accent.contrastRatio(against: surface) >= minimumContrast,
               accent.contrastRatio(against: surface.mixed(with: white, amount: sheen)) >= minimumContrast {
                return surface
            }
        }
        return background
    }
}

enum FullScreenPlayerControlProminence {
    case primary
    case secondary
    case selected
    case destructive

    var fillOpacity: Double {
        switch self {
        case .primary:
            0.40
        case .selected:
            0.34
        case .destructive:
            0.24
        case .secondary:
            0.24
        }
    }

    var pressedFillOpacity: Double {
        switch self {
        case .primary:
            0.48
        case .selected:
            0.42
        case .destructive:
            0.32
        case .secondary:
            0.30
        }
    }

    var strokeOpacity: Double {
        switch self {
        case .primary:
            0.68
        case .selected:
            0.58
        case .destructive:
            0.48
        case .secondary:
            0.44
        }
    }
}

struct FullScreenPlayerGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    var palette: FullScreenPlayerControlPalette
    var prominence: FullScreenPlayerControlProminence = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .playerLegibleForeground(
                prominence == .selected ? palette.selectedForegroundRGB : palette.foregroundRGB,
                fallback: foregroundColor,
                glass: palette.glassTint(for: prominence),
                isActive: isEnabled && palette.usesGlass
            )
            // Dim the label, not the glass: opacity around glass hides what
            // is behind it.
            .opacity(isEnabled ? 1 : 0.46)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Capsule())
            .fullScreenPlayerGlassBackdrop(
                palette,
                shape: Capsule(),
                prominence: prominence,
                isPressed: configuration.isPressed,
                isInteractive: true
            )
            .scaleEffect(configuration.isPressed && !palette.usesGlass ? 0.975 : 1)
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
            .animation(.smooth(duration: 0.16), value: isEnabled)
    }

    private var foregroundColor: Color {
        // A pushed button keeps the background colour even when disabled;
        // the button's opacity dims it.
        if prominence == .selected { return palette.selectedForeground }
        return isEnabled ? palette.foreground : palette.disabledForeground
    }
}

enum FullScreenPlayerFallbackButtonStyle {
    case bordered
    case borderedProminent
}

private struct FullScreenPlayerControlStyleModifier: ViewModifier {
    var palette: FullScreenPlayerControlPalette?
    var prominence: FullScreenPlayerControlProminence
    var fallbackTint: Color
    var fallbackStyle: FullScreenPlayerFallbackButtonStyle

    func body(content: Content) -> some View {
        if let palette {
            content.buttonStyle(FullScreenPlayerGlassButtonStyle(palette: palette, prominence: prominence))
        } else {
            switch fallbackStyle {
            case .bordered:
                content
                    .buttonStyle(.bordered)
                    .tint(fallbackTint)
            case .borderedProminent:
                content
                    .buttonStyle(.borderedProminent)
                    .tint(fallbackTint)
            }
        }
    }
}

private struct FullScreenPlayerGlassBackdropModifier<S: InsettableShape>: ViewModifier {
    var palette: FullScreenPlayerControlPalette?
    var shape: S
    var prominence: FullScreenPlayerControlProminence
    var isPressed: Bool
    var isInteractive: Bool

    func body(content: Content) -> some View {
        if let palette {
            content.fullScreenPlayerGlassBackdropContent(
                palette,
                shape: shape,
                prominence: prominence,
                isPressed: isPressed,
                isInteractive: isInteractive
            )
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

private extension View {
    /// Clear Liquid Glass over the player's art background
    /// (`PlayerGlassArtBackground`): accent-tinted when pushed, untinted
    /// otherwise. Labels pick a readable colour for the art under them
    /// (`PlayerLegibleForeground`).
    @ViewBuilder
    func fullScreenPlayerGlassBackdropContent<S: InsettableShape>(
        _ palette: FullScreenPlayerControlPalette,
        shape: S,
        prominence: FullScreenPlayerControlProminence,
        isPressed: Bool,
        isInteractive: Bool
    ) -> some View {
        if palette.usesGlass {
            // No outline or drop shadow: the glass's own rim, where it
            // lenses what is behind it, has to stay visible.
            if prominence == .selected {
                // Glass has no selected state; on is the accent tint, as
                // with the system's prominent glass buttons.
                glassEffect(.clear.tint(palette.tint.opacity(0.5)).interactive(isInteractive), in: shape)
            } else {
                // Pressing is the glass's own interactive response.
                glassEffect(.clear.interactive(isInteractive), in: shape)
            }
        } else if prominence == .selected {
            background { shape.fill(palette.tint) }
                .overlay {
                    shape
                        .strokeBorder(palette.selectedForeground.opacity(isPressed ? 0.42 : 0.58), lineWidth: 1)
                }
                .shadow(color: .black.opacity(palette.shadowOpacity), radius: 12, y: 7)
        } else {
            background { shape.fill(palette.surface.opacity(isPressed ? 0.94 : 0.76)) }
                .overlay {
                    shape
                        .strokeBorder(
                            palette.tint.opacity(isPressed ? min(prominence.strokeOpacity + 0.20, 0.90) : max(prominence.strokeOpacity, 0.62)),
                            lineWidth: 1
                        )
                        .overlay {
                            shape
                                .strokeBorder(palette.selectedForeground.opacity(0.16), lineWidth: 0.5)
                        }
                }
                .shadow(
                    color: .black.opacity(palette.shadowOpacity),
                    radius: prominence == .primary ? 18 : 12,
                    y: prominence == .primary ? 10 : 7
                )
        }
    }
}

extension View {
    func fullScreenPlayerControlStyle(
        palette: FullScreenPlayerControlPalette?,
        prominence: FullScreenPlayerControlProminence = .secondary,
        fallbackTint: Color = .secondary.opacity(0.24),
        fallbackStyle: FullScreenPlayerFallbackButtonStyle = .borderedProminent
    ) -> some View {
        modifier(FullScreenPlayerControlStyleModifier(
            palette: palette,
            prominence: prominence,
            fallbackTint: fallbackTint,
            fallbackStyle: fallbackStyle
        ))
    }

    func fullScreenPlayerGlassBackdrop<S: InsettableShape>(
        _ palette: FullScreenPlayerControlPalette?,
        shape: S,
        prominence: FullScreenPlayerControlProminence = .secondary,
        isPressed: Bool = false,
        isInteractive: Bool = false
    ) -> some View {
        modifier(FullScreenPlayerGlassBackdropModifier(
            palette: palette,
            shape: shape,
            prominence: prominence,
            isPressed: isPressed,
            isInteractive: isInteractive
        ))
    }
}
