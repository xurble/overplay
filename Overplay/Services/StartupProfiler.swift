import Foundation
import OSLog

enum StartupProfiler {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "Startup"
    )

    @discardableResult
    static func measure<T>(_ label: String, operation: () throws -> T) rethrows -> T {
        let start = Date()
        mark("BEGIN \(label)")
        defer {
            mark("END \(label) (\(formatElapsedTime(since: start)))")
        }

        return try operation()
    }

    @discardableResult
    static func measure<T>(_ label: String, operation: () async throws -> T) async rethrows -> T {
        let start = Date()
        mark("BEGIN \(label)")
        defer {
            mark("END \(label) (\(formatElapsedTime(since: start)))")
        }

        return try await operation()
    }

    static func mark(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    private static func formatElapsedTime(since start: Date) -> String {
        let milliseconds = Date().timeIntervalSince(start) * 1_000
        return String(format: "%.1f ms", milliseconds)
    }
}
