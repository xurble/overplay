import SwiftUI

/// A horizontally scrolling row of artwork tiles: Recent Deep Dives, Made For
/// You and a deep dive's discography. A mouse with no horizontal scrolling
/// cannot move it, so on a Mac, while the pointer is over the row, back and
/// forward buttons at its ends scroll it a page of whole tiles at a time.
struct TileStripView<Data: RandomAccessCollection, Tile: View>: View where Data.Element: Identifiable {
    var data: Data
    @ViewBuilder var tile: (Data.Element) -> Tile

    init(_ data: Data, @ViewBuilder tile: @escaping (Data.Element) -> Tile) {
        self.data = data
        self.tile = tile
    }

    @State private var geometry = TileStripPaging.Geometry()
    @State private var isHovering = false

    private let showsPageButtons = ProcessInfo.processInfo.isMacCatalystApp

    var body: some View {
        // A reader, not a scroll position binding: the binding is written
        // back as the row moves, which cut the paging animation short.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TileStripPaging.spacing) {
                    ForEach(data) { tile($0) }
                }
                .scrollTargetLayout()
                .padding(.horizontal, TileStripPaging.inset)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .onScrollGeometryChange(for: TileStripPaging.Geometry.self) { scroll in
                TileStripPaging.Geometry(offset: scroll.contentOffset.x,
                                         maxOffset: max(0, scroll.contentSize.width - scroll.containerSize.width),
                                         width: scroll.containerSize.width)
            } action: { _, new in
                geometry = new
            }
            .overlay(alignment: .topLeading) {
                if showsPageButtons, isHovering, geometry.canPageBack {
                    pageButton(-1, proxy: proxy)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsPageButtons, isHovering, geometry.canPageForward {
                    pageButton(1, proxy: proxy)
                }
            }
            .onHover { hovering in
                withAnimation(.smooth(duration: 0.2)) { isHovering = hovering }
            }
        }
    }

    private func pageButton(_ direction: Int, proxy: ScrollViewProxy) -> some View {
        Button {
            let index = TileStripPaging.targetIndex(from: geometry, direction: direction, count: data.count)
            let id = data[data.index(data.startIndex, offsetBy: index)].id
            withAnimation(.smooth(duration: 0.45)) {
                proxy.scrollTo(id, anchor: TileStripPaging.anchor(width: geometry.width))
            }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(direction < 0 ? "Scroll Back" : "Scroll Forward")
        // Centred on the artwork, just inside the row's edge.
        .padding(.top, (RecentTileView.side - 30) / 2)
        .padding(.horizontal, 4)
        .transition(.opacity)
    }
}

/// Where the Mac's page buttons scroll a tile strip: a page of whole tiles,
/// so the first tile lands where the row starts, never past either end.
enum TileStripPaging {
    static let spacing: CGFloat = 14
    static let inset: CGFloat = 16
    static var step: CGFloat { RecentTileView.side + spacing }

    struct Geometry: Equatable {
        var offset: CGFloat = 0
        var maxOffset: CGFloat = 0
        var width: CGFloat = 0

        var canPageBack: Bool { offset > 1 }
        var canPageForward: Bool { offset < maxOffset - 1 }
    }

    /// The tile a page button brings to the row's start: a page of whole
    /// tiles on from the tile there now, within the row. The scroll view
    /// stops at its end by itself.
    static func targetIndex(from geometry: Geometry, direction: Int, count: Int) -> Int {
        let tilesPerPage = max(1, Int(((geometry.width - 2 * inset + spacing) / step).rounded(.down)))
        let tile = Int((geometry.offset / step).rounded())
        return min(max(0, tile + direction * tilesPerPage), max(0, count - 1))
    }

    /// The anchor that puts a tile where the row starts, inside its inset,
    /// as swiping does: the tile's and the row's anchor points coincide.
    static func anchor(width: CGFloat) -> UnitPoint {
        let room = width - RecentTileView.side
        return UnitPoint(x: room > 0 ? min(1, inset / room) : 0, y: 0.5)
    }
}

#Preview {
    TileStripView((0..<12).map { PreviewTile(id: $0) }) { tile in
        RoundedRectangle(cornerRadius: 10)
            .fill(.tint.opacity(0.2 + Double(tile.id) / 20))
            .frame(width: RecentTileView.side, height: RecentTileView.side)
    }
}

private struct PreviewTile: Identifiable {
    var id: Int
}
