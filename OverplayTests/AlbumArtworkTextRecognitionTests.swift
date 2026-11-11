import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Overplay

/// Text recognition must never hold the theme back: the theme waits at most
/// the time limit, then uses the cover's colours alone.
@Suite("Album artwork text recognition")
struct AlbumArtworkTextRecognitionTests {
    @Test("a recognition that never answers still yields a colour-only theme", .timeLimit(.minutes(1)))
    func neverAnsweringRecognitionYieldsColourTheme() async throws {
        let gate = RecognitionGate()
        // The limit passes as soon as it is waited on: no wall-clock wait.
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in await gate.wait(); return [] },
            sleep: { _ in }
        )

        let result = await AlbumArtworkThemeBuilder.theme(
            from: AlbumArtworkThemeInput(artworkData: try Self.coverData(), trackTitle: "Song"),
            coverKey: "cover",
            textRecognition: recognition
        )
        gate.open()

        #expect(result.textRecognition == .timedOut)
        #expect(result.textRecognition?.isFinal == false)
        #expect(!result.theme.isFallback)
        #expect(result.theme.source != .ocr)
    }

    @Test("a failed recognition yields a colour-only theme", .timeLimit(.minutes(1)))
    func failedRecognitionYieldsColourTheme() async throws {
        let timer = TimerProbe()
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in await timer.sleeping.wait(); throw RecognitionError.failed },
            sleep: { _ in await timer.sleep() }
        )

        let result = await AlbumArtworkThemeBuilder.theme(
            from: AlbumArtworkThemeInput(artworkData: try Self.coverData(), trackTitle: "Song"),
            coverKey: "cover",
            textRecognition: recognition
        )

        #expect(result.textRecognition == .failed)
        #expect(result.textRecognition?.isFinal == true)
        #expect(!result.theme.isFallback)
        #expect(result.theme.source != .ocr)
    }

    @Test("a recognition that answers in time is used", .timeLimit(.minutes(1)))
    func answeredRecognitionIsUsed() async throws {
        let text = Self.text("Song")
        let timer = TimerProbe()
        // The answer arrives while the timer sleeps; the timer's cancelled
        // sleep then returns at once, and must not claim a time-out.
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in await timer.sleeping.wait(); return [text] },
            sleep: { _ in await timer.sleep() }
        )

        let outcome = await recognition.recognize(in: try Self.coverImage(), coverKey: "cover")

        #expect(outcome == .recognized([text]))
    }

    @Test("a cover being recognised is not recognised again", .timeLimit(.minutes(1)))
    func coverInFlightIsNotRecognisedAgain() async throws {
        let gate = RecognitionGate()
        let calls = CallCount()
        let sleeps = CallCount()
        // The first run waits for the gate; any later run answers at once
        // with its own text, so a second run would show in the answer.
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in
                let call = calls.increment()
                if call == 1 { await gate.wait() }
                return [Self.text("run \(call)")]
            },
            sleep: { _ in
                // The first request's limit passes at once. The second
                // request is waiting by the time its timer starts, so only
                // then may the first run finish; its limit never passes.
                if sleeps.increment() == 1 { return }
                gate.open()
                await Self.sleepUntilCancelled()
            }
        )
        let image = try Self.coverImage()

        let first = await recognition.recognize(in: image, coverKey: "cover")
        let second = await recognition.recognize(in: image, coverKey: "cover")

        #expect(first == .timedOut)
        #expect(second == .recognized([Self.text("run 1")]))
        #expect(calls.value == 1)
    }

    @Test("a different cover gets its own recognition", .timeLimit(.minutes(1)))
    func otherCoverIsRecognised() async throws {
        let calls = CallCount()
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in [Self.text("run \(calls.increment())")] },
            sleep: { _ in await Self.sleepUntilCancelled() }
        )
        let image = try Self.coverImage()

        let first = await recognition.recognize(in: image, coverKey: "cover")
        let other = await recognition.recognize(in: image, coverKey: "other cover")

        #expect(first == .recognized([Self.text("run 1")]))
        #expect(other == .recognized([Self.text("run 2")]))
        #expect(calls.value == 2)
    }

    @Test("an answer that came too late is used by the next request", .timeLimit(.minutes(1)))
    func lateAnswerIsUsedNextTime() async throws {
        let gate = RecognitionGate()
        let calls = CallCount()
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in
                calls.increment()
                await gate.wait()
                return [Self.text("Song")]
            },
            sleep: { _ in }
        )
        let image = try Self.coverImage()

        let first = await recognition.recognize(in: image, coverKey: "cover")
        gate.open()
        await waitUntil { recognition.hasRecentAnswer(for: "cover") }
        let next = await recognition.recognize(in: image, coverKey: "cover")

        #expect(first == .timedOut)
        #expect(next == .recognized([Self.text("Song")]))
        #expect(next.isFinal)
        #expect(calls.value == 1)
    }

    @Test("only the most recent answers are kept", .timeLimit(.minutes(1)))
    func recentAnswersAreBounded() async throws {
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in [] },
            sleep: { _ in await Self.sleepUntilCancelled() }
        )
        let image = try Self.coverImage()

        for index in 0...AlbumArtworkTextRecognition.maximumRecent {
            _ = await recognition.recognize(in: image, coverKey: "cover \(index)")
            await waitUntil { recognition.hasRecentAnswer(for: "cover \(index)") }
        }

        #expect(!recognition.hasRecentAnswer(for: "cover 0"))
        #expect(recognition.hasRecentAnswer(for: "cover 1"))
        #expect(recognition.hasRecentAnswer(for: "cover \(AlbumArtworkTextRecognition.maximumRecent)"))
    }

    @Test("stalled recognitions are not queued behind", .timeLimit(.minutes(1)))
    func stalledRecognitionsAreSkipped() async throws {
        let gate = RecognitionGate()
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in await gate.wait(); return [] },
            sleep: { _ in }
        )
        let image = try Self.coverImage()

        for index in 0..<AlbumArtworkTextRecognition.maximumInFlight {
            #expect(await recognition.recognize(in: image, coverKey: "cover \(index)") == .timedOut)
        }
        let skipped = await recognition.recognize(in: image, coverKey: "one more")
        gate.open()

        #expect(skipped == .skipped)
        #expect(skipped.isFinal == false)
    }

    // MARK: - Helpers

    private enum RecognitionError: Error { case failed }

    private nonisolated static func text(_ value: String) -> AlbumArtworkRecognizedText {
        AlbumArtworkRecognizedText(text: value, confidence: 0.9, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A time limit that never passes: it returns only when cancelled.
    private nonisolated static func sleepUntilCancelled() async {
        await CancellableWait().wait()
    }

    /// A two-colour cover: deep blue with a yellow block.
    private static func coverImage() throws -> CGImage {
        let size = 64
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RecognitionError.failed }
        context.setFillColor(CGColor(red: 0.05, green: 0.20, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(red: 0.96, green: 0.78, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 16, y: 16, width: 24, height: 24))
        guard let image = context.makeImage() else { throw RecognitionError.failed }
        return image
    }

    private static func coverData() throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RecognitionError.failed
        }
        CGImageDestinationAddImage(destination, try coverImage(), nil)
        guard CGImageDestinationFinalize(destination) else { throw RecognitionError.failed }
        return data as Data
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async {
        while !condition() { await Task.yield() }
    }
}

/// Waits until its task is cancelled.
private nonisolated final class CancellableWait: Sendable {
    private let state = Mutex<(cancelled: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func wait(whileWaiting: @Sendable () -> Void = {}) async {
        await withTaskCancellationHandler {
            whileWaiting()
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    if state.cancelled { return true }
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume()
        }
    }
}

/// A recognition's time limit that passes only when cancelled, as a
/// cancelled `Task.sleep` does. `sleeping` opens once the limit is being
/// waited on, so a recognizer can answer while the timer sleeps.
private nonisolated final class TimerProbe: Sendable {
    let sleeping = RecognitionGate()
    private let wait = CancellableWait()

    func sleep() async {
        await wait.wait(whileWaiting: { sleeping.open() })
    }
}

private nonisolated final class CallCount: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    @discardableResult func increment() -> Int { count.withLock { $0 += 1; return $0 } }
}

/// Holds recognitions until the test opens it.
private nonisolated final class RecognitionGate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
