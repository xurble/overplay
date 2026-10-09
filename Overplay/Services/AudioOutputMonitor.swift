import AVFoundation
import Observation

/// The system's current audio output and volume, for the audio output pill.
/// Read-only: the pill sets the volume through `SystemVolumeControl` and the
/// route through the system route picker. AirPlay itself is the system's;
/// Overplay only shows and opens it, and never configures the audio session.
@MainActor
@Observable
final class AudioOutputMonitor {
    static let shared = AudioOutputMonitor(isLive: true)

    private(set) var ports: [AudioOutputPort]
    private(set) var volume: Float

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var routeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?

    /// A fixed route and volume, for previews.
    init(ports: [AudioOutputPort], volume: Float) {
        self.ports = ports
        self.volume = volume
        isLive = false
    }

    private init(isLive: Bool) {
        ports = []
        volume = 0
        self.isLive = isLive
    }

    func start() {
        users += 1
        guard isLive, users == 1 else { return }
        refresh()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Volume changes arrive on an arbitrary thread.
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { @Sendable [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor in self?.volume = volume }
        }
    }

    func stop() {
        users = max(users - 1, 0)
        guard isLive, users == 0 else { return }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        routeObserver = nil
        volumeObservation = nil
    }

    /// Shows a volume the pill has just set, before the system reports it.
    func showVolume(_ volume: Float) {
        self.volume = volume
    }

    /// Reads the session off the main thread: the read can block, and at
    /// launch that was enough to upset the iPad split view's first layout.
    private func refresh() {
        Task {
            let (outputs, volume) = await Task.detached {
                let session = AVAudioSession.sharedInstance()
                return (session.currentRoute.outputs.map { ($0.portType.rawValue, $0.portName) }, session.outputVolume)
            }.value
            ports = outputs.map { AudioOutputPort(type: AVAudioSession.Port(rawValue: $0.0), name: $0.1) }
            self.volume = volume
        }
    }
}
