import CoreGraphics
import Foundation
import Synchronization

/// Text recognition for the artwork theme, bounded so it never holds the
/// theme back. Vision can take a minute or more on a Mac (its first request
/// waits for a Neural Engine model compile), so a theme waits at most
/// `timeLimit` and then uses the cover's colours alone.
///
/// A cover has at most one recognition at a time: a second request for it
/// waits on the first. Recognitions that outlive their limit keep running,
/// as Vision cannot be cancelled; while `maximumInFlight` are running, more
/// are skipped rather than queued behind them. The last `maximumRecent`
/// answers are kept, so an answer that came too late for one request is
/// used by the next one for that cover instead of running Vision again.
nonisolated final class AlbumArtworkTextRecognition: Sendable {
    typealias Recognizer = @Sendable (CGImage) async throws -> [AlbumArtworkRecognizedText]

    enum Outcome: Equatable, Sendable {
        case recognized([AlbumArtworkRecognizedText])
        case failed
        case timedOut
        case skipped

        var observations: [AlbumArtworkRecognizedText] {
            if case .recognized(let observations) = self { observations } else { [] }
        }

        /// Recognition ran to an answer, so a theme built from it can be kept.
        /// A timed-out or skipped one is worth trying again later.
        var isFinal: Bool {
            switch self {
            case .recognized, .failed: true
            case .timedOut, .skipped: false
            }
        }
    }

    static let shared = AlbumArtworkTextRecognition()
    static let defaultTimeLimit: Duration = .seconds(3)
    /// Room for the player's requests plus a few stalled runs; only a stall
    /// fills it.
    static let maximumInFlight = 4
    static let maximumRecent = 16

    private let recognizer: Recognizer
    private let timeLimit: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let state = Mutex(State())

    private nonisolated enum Work {
        case running(Task<Outcome, Never>)
        case answered(Outcome)
        case skipped
    }

    private nonisolated struct State {
        var inFlight: [String: Task<Outcome, Never>] = [:]
        /// Answers by cover, oldest first.
        var recent: [(coverKey: String, outcome: Outcome)] = []
    }

    init(
        recognizer: @escaping Recognizer = AlbumArtworkTextRecognition.vision,
        timeLimit: Duration = AlbumArtworkTextRecognition.defaultTimeLimit,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.recognizer = recognizer
        self.timeLimit = timeLimit
        self.sleep = sleep
    }

    func recognize(in image: CGImage, coverKey: String) async -> Outcome {
        let work: Work = state.withLock { state in
            if let answer = state.recent.last(where: { $0.coverKey == coverKey }) { return .answered(answer.outcome) }
            if let running = state.inFlight[coverKey] { return .running(running) }
            guard state.inFlight.count < Self.maximumInFlight else { return .skipped }
            let task = Task.detached(priority: .utility) { [recognizer] in
                let outcome: Outcome
                do {
                    outcome = .recognized(try await recognizer(image))
                } catch {
                    AlbumArtworkThemeDiagnostics.log("builder ocr failed: \(error.localizedDescription)")
                    outcome = .failed
                }
                self.finish(coverKey, with: outcome)
                return outcome
            }
            state.inFlight[coverKey] = task
            return .running(task)
        }
        switch work {
        case .answered(let answer):
            AlbumArtworkThemeDiagnostics.log("builder ocr reused an earlier answer")
            return answer
        case .running(let work):
            let outcome = await Self.first(of: work, orTimedOutAfter: timeLimit, sleep: sleep)
            if outcome == .timedOut {
                AlbumArtworkThemeDiagnostics.log("builder ocr timed out after \(self.timeLimit); using the cover's colours")
            }
            return outcome
        case .skipped:
            AlbumArtworkThemeDiagnostics.log("builder ocr skipped: \(Self.maximumInFlight) recognitions still running")
            return .skipped
        }
    }

    /// Whether an answer for this cover is kept for the next request.
    func hasRecentAnswer(for coverKey: String) -> Bool {
        state.withLock { state in state.recent.contains { $0.coverKey == coverKey } }
    }

    private func finish(_ coverKey: String, with outcome: Outcome) {
        state.withLock { state in
            state.inFlight[coverKey] = nil
            state.recent.removeAll { $0.coverKey == coverKey }
            state.recent.append((coverKey, outcome))
            if state.recent.count > Self.maximumRecent { state.recent.removeFirst() }
        }
    }

    /// The recognition's outcome, or `.timedOut` once the limit passes,
    /// whichever comes first. Waiting is abandoned, not the recognition.
    private static func first(
        of work: Task<Outcome, Never>,
        orTimedOutAfter limit: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            let timer = Task.detached {
                await sleep(limit)
                // Cancelled: the answer came first. A cancelled sleep returns
                // at once, so without this it could still claim a time-out.
                guard !Task.isCancelled else { return }
                answer.resume(with: .timedOut)
            }
            Task.detached {
                let outcome = await work.value
                // Answer before waking the timer, so the timer cannot win.
                answer.resume(with: outcome)
                timer.cancel()
            }
        }
    }

    /// Vision, off the Swift concurrency pool: a blocked request holds one
    /// thread of a serial queue rather than one of the pool's few threads.
    static let vision: Recognizer = { image in
        try await withCheckedThrowingContinuation { continuation in
            visionQueue.async {
                continuation.resume(with: Result { try AlbumArtworkThemeBuilder.visionText(in: image) })
            }
        }
    }

    private static let visionQueue = DispatchQueue(label: "farm.poplar.Overplay.artwork-text-recognition", qos: .utility)
}

/// Resumes a continuation once, with whichever answer arrives first.
private nonisolated final class FirstAnswer: Sendable {
    private let continuation: Mutex<CheckedContinuation<AlbumArtworkTextRecognition.Outcome, Never>?>

    init(_ continuation: CheckedContinuation<AlbumArtworkTextRecognition.Outcome, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with outcome: AlbumArtworkTextRecognition.Outcome) {
        let pending = continuation.withLock { pending in
            defer { pending = nil }
            return pending
        }
        pending?.resume(returning: outcome)
    }
}
