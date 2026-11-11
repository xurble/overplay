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
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in throw RecognitionError.failed },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
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
        let text = AlbumArtworkRecognizedText(text: "Song", confidence: 0.9, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in [text] },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )

        let outcome = await recognition.recognize(in: try Self.coverImage(), coverKey: "cover")

        #expect(outcome == .recognized([text]))
    }

    @Test("a cover being recognised is not recognised again", .timeLimit(.minutes(1)))
    func coverInFlightIsNotRecognisedAgain() async throws {
        let gate = RecognitionGate()
        let calls = CallCount()
        let recognition = AlbumArtworkTextRecognition(
            recognizer: { _ in
                calls.increment()
                await gate.wait()
                return []
            },
            sleep: { _ in }
        )
        let image = try Self.coverImage()

        let first = await recognition.recognize(in: image, coverKey: "cover")
        let second = await recognition.recognize(in: image, coverKey: "cover")
        let other = await recognition.recognize(in: image, coverKey: "other cover")
        await waitUntil { calls.value >= 2 }
        gate.open()

        #expect(first == .timedOut)
        #expect(second == .timedOut)
        #expect(other == .timedOut)
        #expect(calls.value == 2)
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

private nonisolated final class CallCount: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
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
