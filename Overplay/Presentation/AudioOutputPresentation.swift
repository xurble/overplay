import AVFoundation
import CoreGraphics

/// One output of the current audio route, as `AVAudioSession` reports it.
struct AudioOutputPort: Equatable {
    var type: AVAudioSession.Port
    var name: String
}

/// Text and volume maths for the audio output pill on Now Playing.
enum AudioOutputPresentation {
    /// The hardware volume buttons move the system volume in sixteenths.
    static let volumeSteps: Float = 16

    /// The route's name: the device's own speaker by device ("iPhone
    /// Speaker"), wired headphones generically, and anything else, AirPlay
    /// and Bluetooth included, by the name the system gives it. A route with
    /// several outputs is named by its first ("Kitchen + 1").
    static func name(for ports: [AudioOutputPort], deviceName: String) -> String {
        var names: [String] = []
        for port in ports {
            let name = displayName(for: port, deviceName: deviceName)
            if !names.contains(name) { names.append(name) }
        }
        guard let first = names.first else { return "\(deviceName) Speaker" }
        return names.count == 1 ? first : "\(first) + \(names.count - 1)"
    }

    /// Dragging the full width of the pill moves through the whole range.
    static func volume(from start: Float, dragged translation: CGFloat, across width: CGFloat) -> Float {
        guard width > 0 else { return clamped(start) }
        return clamped(start + Float(translation / width))
    }

    /// The volume a whole number of hardware steps away, as VoiceOver's
    /// adjust gesture moves it.
    static func volume(_ volume: Float, steppedBy steps: Int) -> Float {
        let current = (clamped(volume) * volumeSteps).rounded()
        return clamped((current + Float(steps)) / volumeSteps)
    }

    static func percentText(_ volume: Float) -> String {
        "\(Int((clamped(volume) * 100).rounded())) percent"
    }

    private static func displayName(for port: AudioOutputPort, deviceName: String) -> String {
        switch port.type {
        case .builtInSpeaker, .builtInReceiver:
            return "\(deviceName) Speaker"
        case .headphones:
            return "Headphones"
        default:
            let name = port.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Audio Output" : name
        }
    }

    private static func clamped(_ volume: Float) -> Float {
        min(max(volume, 0), 1)
    }
}
