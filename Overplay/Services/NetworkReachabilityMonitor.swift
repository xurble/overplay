import Foundation
import Network

/// Process-wide network path observer. It records each change of path in the
/// activity log, so a stall can be read against the network it happened on
/// (#84). It never gates or retries playback.
@MainActor
final class NetworkReachabilityMonitor {
    static let shared = NetworkReachabilityMonitor()

    private let monitor = NWPathMonitor()
    private(set) var isReachable = true
    private var lastDescription: String?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isReachable = path.status == .satisfied
            let description = Self.describe(path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReachable = isReachable
                guard description != self.lastDescription else { return }
                self.lastDescription = description
                MusicKitActivityLog.shared.record(.networkPathChanged, detail: description)
            }
        }
        monitor.start(queue: DispatchQueue(label: "overplay.network-reachability", qos: .utility))
    }

    /// Starts observing; the first access creates the monitor.
    func start() {}

    nonisolated static func describe(_ path: NWPath) -> String {
        let interfaces: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.loopback, "loopback"), (.other, "other"),
        ]
        let used = interfaces.filter { path.usesInterfaceType($0.0) }.map(\.1)
        return describe(status: "\(path.status)", interfaces: used,
                        isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    nonisolated static func describe(status: String, interfaces: [String], isExpensive: Bool, isConstrained: Bool) -> String {
        "status=\(status) via=\(interfaces.isEmpty ? "none" : interfaces.joined(separator: "+"))"
            + (isExpensive ? " expensive" : "") + (isConstrained ? " constrained" : "")
    }
}
