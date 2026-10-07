import SwiftData
import SwiftUI

struct PlaybackControlsView: View {
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.modelContext) private var modelContext

    var settings: OverplaySettings
    var controlSize: PlaybackControlSize = .regular
    var artworkTheme: AlbumArtworkTheme? = nil

    var body: some View {
        HStack(spacing: controlSize.spacing) {
            Button {
                Task { await playbackController.previous(context: modelContext) }
            } label: {
                Image(systemName: "backward.fill")
            }
            .accessibilityLabel("Previous track")
            .disabled(!playbackController.hasLiveQueue)
            .buttonStyle(PlaybackControlButtonStyle(
                controlSize: controlSize,
                prominence: .secondary,
                artworkTheme: artworkTheme
            ))

            Button {
                Task { await primaryPlaybackAction() }
            } label: {
                Image(systemName: controlsPresentation.primarySystemImage)
            }
            .accessibilityLabel(controlsPresentation.primaryAccessibilityLabel)
            .disabled(!canUsePrimaryPlaybackAction)
            .buttonStyle(PlaybackControlButtonStyle(
                controlSize: controlSize,
                prominence: .primary,
                artworkTheme: artworkTheme
            ))

            Button {
                Task { await playbackController.next(settings: settings, context: modelContext) }
            } label: {
                Image(systemName: controlsPresentation.skipForwardSystemImage)
            }
            .accessibilityLabel(controlsPresentation.skipForwardAccessibilityLabel)
            .disabled(!playbackController.hasLiveQueue)
            .buttonStyle(PlaybackControlButtonStyle(
                controlSize: controlSize,
                prominence: .secondary,
                artworkTheme: artworkTheme
            ))
        }
    }

    /// Pause is never disabled, and Play works whenever there is a live queue,
    /// a playback intent to resume, or a default playlist (`PLAY-014`).
    private var canUsePrimaryPlaybackAction: Bool {
        playbackController.isPlaying
            || playbackController.hasLiveQueue
            || playbackController.intent != nil
            || (try? PlaybackTrackResolver.defaultPlaybackPlaylist(
                settings: settings,
                in: modelContext
            )) != nil
    }

    private var controlsPresentation: PlaybackControlsPresentation {
        NowPlayingPresentationFactory.playbackControlsPresentation(playbackController: playbackController)
    }

    private func primaryPlaybackAction() async {
        await playbackController.performPrimaryPlaybackAction(settings: settings, context: modelContext)
    }
}

enum PlaybackControlSize {
    case compact
    case regular

    var spacing: CGFloat {
        switch self {
        case .compact:
            14
        case .regular:
            22
        }
    }

    var primaryButtonSize: CGFloat {
        switch self {
        case .compact:
            42
        case .regular:
            68
        }
    }

    var primaryIconSize: CGFloat {
        switch self {
        case .compact:
            18
        case .regular:
            28
        }
    }

    var secondaryIconSize: CGFloat {
        switch self {
        case .compact:
            16
        case .regular:
            24
        }
    }

    var secondaryButtonSize: CGFloat {
        switch self {
        case .compact:
            34
        case .regular:
            48
        }
    }
}

private struct PlaybackControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    enum Prominence {
        case primary
        case secondary
    }

    var controlSize: PlaybackControlSize
    var prominence: Prominence
    var artworkTheme: AlbumArtworkTheme?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: iconSize, weight: iconWeight))
            .playerLegibleForeground(
                palette?.foregroundRGB,
                fallback: foregroundStyle,
                glass: palette?.glassTint(for: .secondary),
                isActive: isEnabled && palette?.usesGlass == true
            )
            // Dim the icon, not the glass.
            .opacity(isEnabled ? 1 : 0.42)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
            .playbackControlBackdrop(
                palette,
                prominence: glassProminence,
                isPressed: configuration.isPressed,
                fallbackOpacity: backgroundOpacity(isPressed: configuration.isPressed)
            )
            .scaleEffect(configuration.isPressed && palette?.usesGlass != true ? 0.92 : 1)
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
            .animation(.smooth(duration: 0.16), value: isEnabled)
    }

    private var buttonSize: CGFloat {
        switch prominence {
        case .primary:
            controlSize.primaryButtonSize
        case .secondary:
            controlSize.secondaryButtonSize
        }
    }

    private var iconSize: CGFloat {
        switch prominence {
        case .primary:
            controlSize.primaryIconSize
        case .secondary:
            controlSize.secondaryIconSize
        }
    }

    private var iconWeight: Font.Weight {
        prominence == .primary ? .bold : .semibold
    }

    private var palette: FullScreenPlayerControlPalette? {
        artworkTheme.flatMap(FullScreenPlayerControlPalette.init(theme:))
    }

    private var foregroundStyle: Color {
        guard let palette else {
            return isEnabled ? .primary : .secondary.opacity(0.55)
        }

        guard isEnabled else {
            return palette.disabledForeground
        }

        return palette.foreground
    }

    private var glassProminence: FullScreenPlayerControlProminence {
        prominence == .primary ? .primary : .secondary
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        switch prominence {
        case .primary:
            isPressed ? 0.78 : 1
        case .secondary:
            isPressed ? 0.42 : 0.18
        }
    }
}

private struct PlaybackControlBackdropModifier: ViewModifier {
    var palette: FullScreenPlayerControlPalette?
    var prominence: FullScreenPlayerControlProminence
    var isPressed: Bool
    var fallbackOpacity: Double

    func body(content: Content) -> some View {
        if let palette {
            content.fullScreenPlayerGlassBackdrop(
                palette,
                shape: Circle(),
                prominence: prominence,
                isPressed: isPressed,
                isInteractive: true
            )
        } else {
            content
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(fallbackOpacity)
                }
                .overlay {
                    Circle()
                        .stroke(.white.opacity(isPressed ? 0.24 : 0.12), lineWidth: 1)
                }
        }
    }
}

private extension View {
    func playbackControlBackdrop(
        _ palette: FullScreenPlayerControlPalette?,
        prominence: FullScreenPlayerControlProminence,
        isPressed: Bool,
        fallbackOpacity: Double
    ) -> some View {
        modifier(PlaybackControlBackdropModifier(
            palette: palette,
            prominence: prominence,
            isPressed: isPressed,
            fallbackOpacity: fallbackOpacity
        ))
    }
}

#Preview {
    PlaybackControlsView(settings: OverplaySettings())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}
