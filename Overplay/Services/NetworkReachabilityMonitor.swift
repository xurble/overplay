import Foundation
import Network

/// Process-wide network path observer used to gate playback stall-recovery
/// retries. Defaults to reachable until the first path update arrives so a
/// slow first callback can never block a recovery attempt.
@MainActor
final class NetworkReachabilityMonitor {
    static let shared = NetworkReachabilityMonitor()

    private let monitor = NWPathMonitor()
    private(set) var isReachable = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isReachable = isReachable
            }
        }
        monitor.start(queue: DispatchQueue(label: "overplay.network-reachability", qos: .utility))
    }
}
