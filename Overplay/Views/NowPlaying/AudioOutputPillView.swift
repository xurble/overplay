import AVFoundation
import SwiftUI
import UIKit

/// Where audio is playing, filled to the system volume. Drag across it to
/// change the volume; tap it to choose an output, AirPlay included, in the
/// system picker.
struct AudioOutputPillView: View {
    /// The Mac has its own output menu, and its volume cannot be set this way.
    static var isAvailable: Bool { !ProcessInfo.processInfo.isMacCatalystApp }
    static let size = CGSize(width: 180, height: 32)
    /// Between the transport's row and the pill.
    static let gap: CGFloat = 12
    /// The pill and the gap above it, below the transport.
    static var rowHeight: CGFloat { gap + size.height }

    var artworkTheme: AlbumArtworkTheme? = nil
    /// False while the player sheet is collapsed and the pill hidden, so the
    /// system volume overlay works everywhere else.
    var isExpanded = true
    var monitor: AudioOutputMonitor = .shared

    private let volumeControl = SystemVolumeControl.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var routePicker = AudioRoutePickerControl()
    @State private var width: CGFloat = 0
    /// The volume when a drag began; reset by SwiftUI when the drag ends or
    /// is cancelled, so a cancelled drag cannot stop the pill following
    /// the volume buttons.
    @GestureState private var dragStartVolume: Float?
    @State private var isVolumeControlAttached = false

    var body: some View {
        HStack(spacing: 8) {
            AudioRoutePickerView(control: routePicker, tint: iconTint)
                .frame(width: 18, height: 18)
            Text(outputName)
                .lineLimit(1)
                .playerLegibleForeground(
                    palette?.foregroundRGB,
                    fallback: palette?.foreground ?? .primary,
                    glass: palette?.glassTint(for: .secondary),
                    isActive: palette?.usesGlass ?? false
                )
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 12)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(alignment: .leading) {
            Rectangle()
                .fill(fillColor)
                .frame(width: width * CGFloat(monitor.volume))
                .animation(dragStartVolume == nil ? .smooth(duration: 0.2) : nil, value: monitor.volume)
        }
        .clipShape(Capsule())
        .contentShape(Capsule())
        .fullScreenPlayerGlassBackdrop(palette, shape: Capsule())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .highPriorityGesture(volumeDrag)
        .onTapGesture { routePicker.present() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio output")
        .accessibilityValue("\(outputName), volume \(AudioOutputPresentation.percentText(monitor.volume))")
        .accessibilityHint("Double-tap to choose where audio plays.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { routePicker.present() }
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                setVolume(AudioOutputPresentation.volume(monitor.volume, steppedBy: 1))
            case .decrement:
                setVolume(AudioOutputPresentation.volume(monitor.volume, steppedBy: -1))
            @unknown default:
                break
            }
        }
        .accessibilityIdentifier("audio-output-pill")
        .onAppear {
            monitor.start()
            setVolumeControlAttached(isExpanded)
        }
        .onDisappear {
            monitor.stop()
            setVolumeControlAttached(false)
        }
        .onChange(of: isExpanded) { _, isExpanded in
            setVolumeControlAttached(isExpanded)
        }
        // The volume buttons, while the pill is on screen: in the background
        // (music playing, the phone in a pocket) nobody sees it.
        .task(id: isExpanded && scenePhase == .active) {
            guard isExpanded, scenePhase == .active else { return }
            // The session's volume is stale (its session is never active):
            // while this reads the real one, the session's must not land on it.
            monitor.followsVolumeElsewhere = true
            defer { monitor.followsVolumeElsewhere = false }
            while !Task.isCancelled {
                if dragStartVolume == nil, let volume = volumeControl.currentVolume, abs(volume - monitor.volume) > 0.001 {
                    monitor.showVolume(volume)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private var volumeDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragStartVolume) { _, start, _ in
                if start == nil { start = monitor.volume }
            }
            .onChanged { value in
                setVolume(AudioOutputPresentation.volume(
                    from: dragStartVolume ?? monitor.volume,
                    dragged: value.translation.width,
                    across: width
                ))
            }
    }

    private func setVolumeControlAttached(_ attached: Bool) {
        guard attached != isVolumeControlAttached else { return }
        isVolumeControlAttached = attached
        if attached {
            volumeControl.attach()
        } else {
            volumeControl.detach()
        }
    }

    private func setVolume(_ volume: Float) {
        if volumeControl.setVolume(volume) {
            monitor.showVolume(volume)
        }
    }

    private var outputName: String {
        AudioOutputPresentation.name(for: monitor.ports, deviceName: UIDevice.current.model)
    }

    private var palette: FullScreenPlayerControlPalette? {
        artworkTheme.flatMap(FullScreenPlayerControlPalette.init(theme:))
    }

    private var iconTint: Color {
        palette?.foreground ?? .primary
    }

    private var fillColor: Color {
        palette.map { $0.foreground.opacity(0.24) } ?? Color.primary.opacity(0.16)
    }
}

#Preview {
    VStack(spacing: 16) {
        AudioOutputPillView(
            monitor: AudioOutputMonitor(ports: [AudioOutputPort(type: .builtInSpeaker, name: "Speaker")], volume: 0.5)
        )
        AudioOutputPillView(
            monitor: AudioOutputMonitor(ports: [AudioOutputPort(type: .airPlay, name: "Big Tee Vee")], volume: 0.8)
        )
    }
    .padding(24)
}
