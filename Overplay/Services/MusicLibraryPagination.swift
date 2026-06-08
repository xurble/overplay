import Foundation

struct MusicLibraryPage<Item, Cursor> {
    var items: [Item]
    var nextCursor: Cursor?
}

enum MusicLibraryPagination {
    static func collect<Item, Cursor>(
        firstPage: () async throws -> MusicLibraryPage<Item, Cursor>,
        nextPage: (Cursor) async throws -> MusicLibraryPage<Item, Cursor>?
    ) async throws -> [Item] {
        var page = try await firstPage()
        var items = page.items

        while let cursor = page.nextCursor {
            guard let next = try await nextPage(cursor) else {
                break
            }

            items.append(contentsOf: next.items)
            page = next
        }

        return items
    }
}
