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
                .foregroundStyle(artworkTheme?.trackTitle ?? .primary)
                .multilineTextAlignment(.center)
                .lineLimit(titleLineLimit)
                .minimumScaleFactor(0.78)

            Text(presentation.artistName)
                .font(artistFont)
                .foregroundStyle(artworkTheme?.artistName ?? .secondary)
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
                .foregroundStyle(artworkTheme.albumName)
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
                Spacer()
                Text(presentation.durationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(foreground ?? .secondary)
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
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Capsule()
                                .fill(.white.opacity(0.08))
                        }
                        .overlay {
                            Capsule()
                                .strokeBorder(.white.opacity(0.34), lineWidth: 1)
                        }
                        .overlay {
                            Capsule()
                                .strokeBorder(.black.opacity(0.18), lineWidth: 0.5)
                                .padding(1)
                        }

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
        .foregroundStyle(controlPalette?.foreground ?? .primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fullScreenPlayerGlassBackdrop(controlPalette, shape: Capsule(), prominence: .secondary)
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
/// same minimum contrast, sheen included.
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
    /// Unpushed fill for the primary transport control: more tint, same rule.
    let primarySurfaceRGB: AlbumArtworkRGBColor
    /// The pushed fill's highlight at its corner, as strong as the contrast
    /// allows. The label sits mid-gradient, where it is half as strong.
    let selectedSheenOpacity: Double

    init?(theme: AlbumArtworkTheme?) {
        guard let theme, !theme.isFallback else { return nil }
        let background = theme.backgroundRGB
        let isLight = background.relativeLuminance > 0.34
        let surfaceSheen = Self.surfaceSheenAtLabel(isLight: isLight)
        let accent = Self.accent(theme.trackTitleRGB, against: background, surfaceSheen: surfaceSheen)

        backgroundRGB = background
        accentRGB = accent
        surfaceRGB = Self.tonalSurface(
            background, accent: accent, preferredTint: isLight ? 0.14 : 0.20, sheen: surfaceSheen
        )
        primarySurfaceRGB = Self.tonalSurface(
            background, accent: accent, preferredTint: isLight ? 0.24 : 0.32, sheen: surfaceSheen
        )
        selectedSheenOpacity = [0.22, 0.12, 0.06].first {
            background.contrastRatio(against: accent.mixed(with: Self.white, amount: $0 / 2)) >= Self.minimumContrast
        }.map(Double.init) ?? 0
    }

    /// The unpushed sheen's middle stop, where the label sits.
    static func surfaceSheenAtLabel(isLight: Bool) -> CGFloat {
        isLight ? 0.03 : 0.08
    }

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

    var surface: Color {
        surfaceRGB.color
    }

    var primarySurface: Color {
        primarySurfaceRGB.color
    }

    var isLightBackground: Bool {
        backgroundRGB.relativeLuminance > 0.34
    }

    var shadowOpacity: Double {
        isLightBackground ? 0.14 : 0.34
    }

    /// Readable on the background, and on the background under the unpushed
    /// sheen, so an untinted surface always passes. Moves toward black or
    /// white, the further from the background first, never to it.
    private static func accent(
        _ preferred: AlbumArtworkRGBColor,
        against background: AlbumArtworkRGBColor,
        surfaceSheen: CGFloat
    ) -> AlbumArtworkRGBColor {
        let sheened = background.mixed(with: white, amount: surfaceSheen)
        func worstContrast(_ color: AlbumArtworkRGBColor) -> CGFloat {
            min(color.contrastRatio(against: background), color.contrastRatio(against: sheened))
        }
        let extremes = [white, black].sorted { $0.contrastRatio(against: background) > $1.contrastRatio(against: background) }
        for extreme in extremes {
            for step in 0...10 {
                let candidate = preferred.mixed(with: extreme, amount: CGFloat(step) / 10)
                if worstContrast(candidate) >= minimumContrast { return candidate }
            }
        }
        return extremes.max { worstContrast($0) < worstContrast($1) } ?? black
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
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Capsule())
            .fullScreenPlayerGlassBackdrop(
                palette,
                shape: Capsule(),
                prominence: prominence,
                isPressed: configuration.isPressed
            )
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.46)
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

    func body(content: Content) -> some View {
        if let palette {
            content.fullScreenPlayerGlassBackdropContent(
                palette,
                shape: shape,
                prominence: prominence,
                isPressed: isPressed
            )
        } else {
            content.background(.thinMaterial, in: shape)
        }
    }
}

private extension View {
    @ViewBuilder
    func fullScreenPlayerGlassBackdropContent<S: InsettableShape>(
        _ palette: FullScreenPlayerControlPalette,
        shape: S,
        prominence: FullScreenPlayerControlProminence,
        isPressed: Bool
    ) -> some View {
        if prominence == .selected {
            background {
                // Opaque, so the background-coloured text keeps its contrast.
                shape
                    .fill(palette.tint)
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isPressed ? palette.selectedSheenOpacity / 2 : palette.selectedSheenOpacity),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
            }
            .overlay {
                shape
                    .strokeBorder(palette.selectedForeground.opacity(isPressed ? 0.42 : 0.58), lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(palette.shadowOpacity),
                radius: 12,
                y: 7
            )
        } else {
            background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill((prominence == .primary ? palette.primarySurface : palette.surface)
                            .opacity(isPressed ? 0.94 : 0.76))
                    }
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(palette.isLightBackground ? 0.12 : 0.22),
                                    .white.opacity(Double(FullScreenPlayerControlPalette.surfaceSheenAtLabel(
                                        isLight: palette.isLightBackground
                                    ))),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                    }
            }
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
        isPressed: Bool = false
    ) -> some View {
        modifier(FullScreenPlayerGlassBackdropModifier(
            palette: palette,
            shape: shape,
            prominence: prominence,
            isPressed: isPressed
        ))
    }
}
