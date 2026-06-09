import SwiftData
import SwiftUI

struct NowPlayingArtworkView: View {
    var urlString: String?
    var playlistID: String?
    var cornerRadius: CGFloat = 18

    var body: some View {
        ArtworkView(
            urlString: urlString,
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

struct TrackHealthStatusView: View {
    var presentation: NowPlayingPresentation
    var artworkTheme: AlbumArtworkTheme? = nil

    var body: some View {
        HStack(spacing: 14) {
            Label(presentation.skipCountText, systemImage: "forward.end.fill")

            if presentation.isEvicted {
                let healthPresentation = TrackHealthPresentation(status: .critical, isEvicted: true, isProtected: false)
                Label(healthPresentation.title, systemImage: healthPresentation.systemImage)
                    .foregroundStyle(.red)
            }

            if presentation.isProtected {
                let healthPresentation = TrackHealthPresentation(status: .healthy, isEvicted: false, isProtected: true)
                Label(healthPresentation.title, systemImage: healthPresentation.systemImage)
                    .foregroundStyle(.green)
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
    @Environment(AppRuntime.self) private var runtime
    @Environment(PlaybackController.self) private var playbackController

    var artworkTheme: AlbumArtworkTheme? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await playbackController.toggleShuffle(context: modelContext)
                    runtime.remoteCommandService.syncPlaybackModes(from: playbackController)
                }
            } label: {
                Label(controlsPresentation.shuffleTitle, systemImage: controlsPresentation.shuffleSystemImage)
                    .frame(maxWidth: .infinity)
            }
            .fullScreenPlayerControlStyle(
                palette: controlPalette,
                prominence: controlsPresentation.shuffleEnabled ? .selected : .secondary,
                fallbackTint: controlsPresentation.shuffleEnabled ? .accentColor : .secondary.opacity(0.24)
            )

            Button {
                playbackController.toggleRepeat()
                runtime.remoteCommandService.syncPlaybackModes(from: playbackController)
            } label: {
                Label(controlsPresentation.repeatTitle, systemImage: controlsPresentation.repeatSystemImage)
                    .frame(maxWidth: .infinity)
            }
            .fullScreenPlayerControlStyle(
                palette: controlPalette,
                prominence: controlsPresentation.repeatEnabled ? .selected : .secondary,
                fallbackTint: controlsPresentation.repeatEnabled ? .accentColor : .secondary.opacity(0.24)
            )
        }
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
            Button {
                playbackController.keepCurrent(settings: settings, context: modelContext)
            } label: {
                Label("Keep", systemImage: "heart.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(playbackController.currentTrack == nil)
            .fullScreenPlayerControlStyle(
                palette: controlPalette,
                prominence: .secondary,
                fallbackStyle: .bordered
            )

            Button(role: .destructive) {
                Task { await playbackController.evictCurrent(settings: settings, context: modelContext) }
            } label: {
                Label("Evict Now", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(playbackController.currentTrack == nil)
            .fullScreenPlayerControlStyle(
                palette: controlPalette,
                prominence: .destructive,
                fallbackStyle: .bordered
            )
        }
    }

    private var controlPalette: FullScreenPlayerControlPalette? {
        artworkTheme.flatMap(FullScreenPlayerControlPalette.init(theme:))
    }
}

struct FullScreenPlayerControlPalette: Equatable {
    let backgroundRGB: AlbumArtworkRGBColor
    let accentRGB: AlbumArtworkRGBColor
    let foregroundRGB: AlbumArtworkRGBColor

    init?(theme: AlbumArtworkTheme?) {
        guard let theme, !theme.isFallback else { return nil }
        self.backgroundRGB = theme.backgroundRGB
        self.accentRGB = theme.trackTitleRGB
        self.foregroundRGB = theme.trackTitleRGB
    }

    var foreground: Color {
        foregroundRGB.color
    }

    var secondaryForeground: Color {
        subduedForeground(amount: 0.18).color
    }

    var disabledForeground: Color {
        subduedForeground(amount: 0.42).color
    }

    var tint: Color {
        accentRGB.color
    }

    var isLightBackground: Bool {
        backgroundRGB.relativeLuminance > 0.34
    }

    var shadowOpacity: Double {
        isLightBackground ? 0.14 : 0.34
    }

    private func subduedForeground(amount: CGFloat) -> AlbumArtworkRGBColor {
        let mixed = foregroundRGB.mixed(with: backgroundRGB, amount: amount)
        if mixed.contrastRatio(against: backgroundRGB) >= 3.0 {
            return mixed
        }
        return foregroundRGB
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
            0.30
        case .selected:
            0.26
        case .destructive:
            0.18
        case .secondary:
            0.14
        }
    }

    var pressedFillOpacity: Double {
        switch self {
        case .primary:
            0.40
        case .selected:
            0.34
        case .destructive:
            0.26
        case .secondary:
            0.20
        }
    }

    var strokeOpacity: Double {
        switch self {
        case .primary:
            0.58
        case .selected:
            0.48
        case .destructive:
            0.38
        case .secondary:
            0.30
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
        guard isEnabled else { return palette.disabledForeground }
        switch prominence {
        case .selected:
            return palette.backgroundRGB.color
        case .secondary:
            return palette.secondaryForeground
        default:
            return palette.foreground
        }
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
                shape
                    .fill(palette.foreground.opacity(isPressed ? 0.78 : 0.94))
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isPressed ? 0.08 : 0.18),
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
                    .strokeBorder(palette.backgroundRGB.color.opacity(isPressed ? 0.56 : 0.72), lineWidth: 1)
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
                        shape.fill(palette.tint.opacity(isPressed ? prominence.pressedFillOpacity : prominence.fillOpacity))
                    }
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(palette.isLightBackground ? 0.34 : 0.22),
                                    .white.opacity(0.04),
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
                        palette.tint.opacity(isPressed ? prominence.strokeOpacity + 0.14 : prominence.strokeOpacity),
                        lineWidth: 1
                    )
                    .overlay {
                        shape
                            .strokeBorder(.white.opacity(palette.isLightBackground ? 0.18 : 0.12), lineWidth: 0.5)
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
