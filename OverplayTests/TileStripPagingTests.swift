import SwiftUI
import Testing
@testable import Overplay

/// The Mac's page buttons on a tile strip move a page of whole tiles, never
/// past either end, and land a tile where swiping would.
@Suite("Tile strip paging")
struct TileStripPagingTests {
    private let step = TileStripPaging.step

    @Test func forwardMovesAPageOfWholeTiles() {
        // 400 points shows two whole 120-point tiles with their gaps and insets.
        let geometry = TileStripPaging.Geometry(offset: 0, maxOffset: 1000, width: 400)

        #expect(TileStripPaging.targetIndex(from: geometry, direction: 1, count: 10) == 2)
    }

    @Test func backReturnsToTheStart() {
        let geometry = TileStripPaging.Geometry(offset: 2 * step, maxOffset: 1000, width: 400)

        #expect(TileStripPaging.targetIndex(from: geometry, direction: -1, count: 10) == 0)
    }

    @Test func neitherEndIsPassed() {
        let nearEnd = TileStripPaging.Geometry(offset: 8 * step, maxOffset: 1000, width: 400)
        let nearStart = TileStripPaging.Geometry(offset: 40, maxOffset: 1000, width: 400)

        #expect(TileStripPaging.targetIndex(from: nearEnd, direction: 1, count: 10) == 9)
        #expect(TileStripPaging.targetIndex(from: nearStart, direction: -1, count: 10) == 0)
    }

    @Test func aNarrowRowStillMovesOneTile() {
        let geometry = TileStripPaging.Geometry(offset: 0, maxOffset: 1000, width: 100)

        #expect(TileStripPaging.targetIndex(from: geometry, direction: 1, count: 10) == 1)
    }

    @Test func theTargetTileLandsInsideTheRowsInset() {
        let width: CGFloat = 400
        let anchor = TileStripPaging.anchor(width: width)

        // A tile's anchor point meets the row's: its leading edge sits at the inset.
        #expect(abs(anchor.x * (width - RecentTileView.side) - TileStripPaging.inset) < 0.001)
    }

    @Test func buttonsShowOnlyWhereThereIsMoreToSee() {
        #expect(!TileStripPaging.Geometry(offset: 0, maxOffset: 500, width: 400).canPageBack)
        #expect(TileStripPaging.Geometry(offset: 0, maxOffset: 500, width: 400).canPageForward)
        #expect(TileStripPaging.Geometry(offset: 500, maxOffset: 500, width: 400).canPageBack)
        #expect(!TileStripPaging.Geometry(offset: 500, maxOffset: 500, width: 400).canPageForward)
        #expect(!TileStripPaging.Geometry(offset: 0, maxOffset: 0, width: 400).canPageForward)
    }
}
