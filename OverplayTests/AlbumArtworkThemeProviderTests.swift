import Foundation
import Synchronization
import Testing
@testable import Overplay

/// The provider keeps a theme only when text recognition answered, so a
/// cover whose recognition timed out or was skipped gets another try.
@Suite("Album artwork theme provider")
struct AlbumArtworkThemeProviderTests {
    private static let artworkURL = "https://example.com/image/thumb/cover/{w}x{h}bb.jpg"

    @Test("a theme made after recognition timed out is returned but not cached", .timeLimit(.minutes(1)))
    func timedOutRecognitionIsNotCached() async throws {
        let gate = ProviderTestGate()
        let fixture = try Fixture(recognition: AlbumArtworkTextRecognition(
            recognizer: { _ in await gate.wait(); return [] },
            sleep: { _ in }
        ))
        defer { gate.open(); fixture.remove() }

        let theme = await fixture.prepare()

        #expect(!theme.isFallback)
        #expect(await !fixture.isCached())
    }

    @Test("a theme made after recognition failed is cached", .timeLimit(.minutes(1)))
    func failedRecognitionIsCached() async throws {
        let fixture = try Fixture(recognition: AlbumArtworkTextRecognition(
            recognizer: { _ in throw ProviderTestError.failed },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        ))
        defer { fixture.remove() }

        _ = await fixture.prepare()

        #expect(await fixture.isCached())
    }

    @Test("an answer that came too late is cached by the next request without recognising again", .timeLimit(.minutes(1)))
    func lateAnswerIsCachedNextTime() async throws {
        let gate = ProviderTestGate()
        let calls = ProviderCallCount()
        let fixture = try Fixture(recognition: AlbumArtworkTextRecognition(
            recognizer: { _ in
                calls.increment()
                await gate.wait()
                return []
            },
            sleep: { _ in }
        ))
        defer { fixture.remove() }

        _ = await fixture.prepare()
        #expect(await !fixture.isCached())
        gate.open()
        let coverKey = try await fixture.coverKey()
        while !fixture.recognition.hasRecentAnswer(for: coverKey) { await Task.yield() }
        _ = await fixture.prepare()

        #expect(await fixture.isCached())
        #expect(calls.value == 1)
    }

    private struct Fixture {
        let directory: URL
        let recognition: AlbumArtworkTextRecognition
        let artworkCache: ArtworkCacheService
        let provider: AlbumArtworkThemeProvider

        init(recognition: AlbumArtworkTextRecognition) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OverplayThemeProviderTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.recognition = recognition
            artworkCache = ArtworkCacheService(
                rootDirectory: directory.appendingPathComponent("Artwork", isDirectory: true),
                downloader: { _ in artworkTestData() }
            )
            provider = AlbumArtworkThemeProvider(
                store: AlbumArtworkThemeStore(
                    directoryURL: directory.appendingPathComponent("Themes", isDirectory: true),
                    maxEntries: 100,
                    saveDelay: .seconds(60)
                ),
                textRecognition: recognition,
                artworkCache: artworkCache
            )
        }

        func prepare() async -> AlbumArtworkTheme {
            await provider.prepareTheme(
                forArtworkURLTemplate: AlbumArtworkThemeProviderTests.artworkURL,
                playlistID: nil,
                trackTitle: "Song",
                artistName: "Artist",
                albumTitle: "Album",
                requiresIncreasedContrast: false
            )
        }

        func isCached() async -> Bool {
            await provider.hasCachedTheme(forArtworkURLTemplate: AlbumArtworkThemeProviderTests.artworkURL, requiresIncreasedContrast: false)
        }

        /// The cover's key in text recognition: the hash of the artwork the
        /// provider reads.
        func coverKey() async throws -> String {
            let fileURL = try #require(await artworkCache.artworkFileURL(
                for: AlbumArtworkThemeProviderTests.artworkURL,
                pixelSize: AlbumArtworkThemeProvider.artworkPixelSize
            ))
            return AlbumArtworkThemeStore.artworkDataHash(try Data(contentsOf: fileURL))
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

private enum ProviderTestError: Error { case failed }

private nonisolated final class ProviderCallCount: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

/// Holds callers until the test opens it.
private nonisolated final class ProviderTestGate: Sendable {
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
