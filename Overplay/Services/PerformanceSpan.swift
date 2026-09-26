import Foundation
import OSLog

/// Timings appear in the existing persistent activity report and in Instruments.
/// Details must describe work, never tokens, account IDs, or artwork URLs.
nonisolated struct PerformanceSpan {
    @TaskLocal static var correlationID: String?
    private let traceID = Self.correlationID
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay", category: "Performance"
    )
    private let operation: MusicKitActivityOperation
    private let startedAt = Date.now
    private let started = ContinuousClock.now
    private let interval: OSSignpostIntervalState

    init(_ operation: MusicKitActivityOperation) {
        self.operation = operation
        interval = Self.signposter.beginInterval("Overplay work", "\(operation.rawValue, privacy: .public)")
    }

    func finish(magnitude: Double? = nil, detail: String? = nil) {
        Self.signposter.endInterval("Overplay work", interval)
        MusicKitActivityLog.shared.record(operation, startedAt: startedAt,
            duration: started.duration(to: .now), magnitude: magnitude, detail: [traceID, detail].compactMap { $0 }.joined(separator: " "))
    }
}
