import Testing
@testable import Overplay

@Suite("Music library pagination")
struct MusicLibraryPaginationTests {
    @Test("collect fetches every page until the cursor is exhausted")
    func collectFetchesEveryPageUntilCursorIsExhausted() async throws {
        let pages = [
            0: MusicLibraryPage(items: ["A", "B"], nextCursor: 1),
            1: MusicLibraryPage(items: ["C"], nextCursor: 2),
            2: MusicLibraryPage(items: ["D", "E"], nextCursor: Int?.none)
        ]
        var requestedCursors: [Int] = []

        let items = try await MusicLibraryPagination.collect {
            try #require(pages[0])
        } nextPage: { cursor in
            requestedCursors.append(cursor)
            return pages[cursor]
        }

        #expect(items == ["A", "B", "C", "D", "E"])
        #expect(requestedCursors == [1, 2])
    }

    @Test("collect stops when a continuation returns nil")
    func collectStopsWhenContinuationReturnsNil() async throws {
        let items = try await MusicLibraryPagination.collect {
            MusicLibraryPage(items: [1, 2], nextCursor: "missing")
        } nextPage: { _ in
            nil
        }

        #expect(items == [1, 2])
    }
}
