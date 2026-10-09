import AVFoundation

/// Records the system's audio session events in the activity log, so a stall
/// can be read against them (#84): media services lost or reset (the system
/// media server restarting under Overplay), interruptions, and route changes.
/// It only records. Overplay never configures the audio session.
@MainActor
final class AudioSessionEventRecorder {
    static let shared = AudioSessionEventRecorder()

    private var observers: [any NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let events: [(Notification.Name, @Sendable (Notification) -> String)] = [
            (AVAudioSession.mediaServicesWereLostNotification, { _ in "media services lost" }),
            (AVAudioSession.mediaServicesWereResetNotification, { _ in "media services reset" }),
            (AVAudioSession.interruptionNotification, Self.describeInterruption),
            (AVAudioSession.routeChangeNotification, Self.describeRouteChange),
        ]
        observers = events.map { name, describe in
            center.addObserver(forName: name, object: nil, queue: nil) { notification in
                MusicKitActivityLog.shared.record(.audioSessionEvent, detail: describe(notification))
            }
        }
    }

    nonisolated static func describeInterruption(_ notification: Notification) -> String {
        let info = notification.userInfo ?? [:]
        let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
        var parts = ["interruption \(type == .began ? "began" : type == .ended ? "ended" : "unknown")"]
        if let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init) {
            parts.append("reason=\(reason.rawValue)")
        }
        if let options = info[AVAudioSessionInterruptionOptionKey] as? UInt {
            parts.append("shouldResume=\(AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))")
        }
        return parts.joined(separator: " ")
    }

    nonisolated static func describeRouteChange(_ notification: Notification) -> String {
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        return "route changed reason=\(reason) outputs=\(outputs.isEmpty ? "none" : outputs)"
    }
}
