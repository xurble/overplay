import CarPlay
import UIKit

/// Only values visible on a CarPlay list. Persistence timestamps and playback
/// bookkeeping deliberately do not participate in presentation equality.
struct CarPlayListPresentation: Equatable {
    struct Section: Equatable {
        var id: String
        var header: String? = nil
        var rows: [Row]
    }

    struct Row: Equatable {
        /// How the row is drawn. Cards and strips are iOS 26 image rows; they
        /// have no playing indicator.
        enum Style: Equatable {
            case standard
            /// One large artwork card, titled with the row's title and detail.
            case card
            /// The row's title over a strip of tappable artwork tiles.
            case strip([Tile])
        }
        struct Tile: Equatable {
            var id: String
            var title: String
            var subtitle: String? = nil
            var artwork: Artwork? = nil
        }
        enum Artwork: Equatable {
            case symbol(String, tint: UIColor? = nil)
            case track(url: String?, playlistID: String)
            case collage(PlaylistCollage, playlistID: String, scope: PlaylistPlaybackScope)
        }
        var id: String
        var title: String
        var detail: String? = nil
        var isPlaying = false
        var isEnabled = true
        var disclosure = false
        var artwork: Artwork? = nil
        var style: Style = .standard
    }

    var sections: [Section]
}

/// Owns rows for the lifetime of a presented menu. Structural edits replace
/// sections; content edits mutate just the affected fields on existing rows.
@MainActor
final class CarPlayListRenderer {
    typealias Row = CarPlayListPresentation.Row
    private(set) var presentation = CarPlayListPresentation(sections: [])
    private(set) var items: [String: CPListItem] = [:]
    private(set) var imageRows: [String: CPListImageRowItem] = [:]
    /// Image-row elements and their loaded images, keyed by artwork slot
    /// (the row ID for a card, the tile ID for a strip tile).
    private var elements: [String: CPListImageRowItemElement] = [:]
    private var images: [String: UIImage] = [:]
    private var actions: [String: @MainActor () async -> Void] = [:]
    private var requestedArtwork: [String: Row.Artwork] = [:]
    private var loadedArtwork: [String: Row.Artwork] = [:]
    private var artworkTask: Task<Void, Never>?
    private let loadArtwork: @MainActor (Row.Artwork) async -> UIImage?
    private let record: (MusicKitActivityOperation, String) -> Void

    init(
        loadArtwork: @escaping @MainActor (Row.Artwork) async -> UIImage? = CarPlayListRenderer.loadArtwork,
        record: @escaping (MusicKitActivityOperation, String) -> Void = {
            MusicKitActivityLog.shared.record($0, detail: $1)
        }
    ) {
        self.loadArtwork = loadArtwork
        self.record = record
    }

    func stop() {
        artworkTask?.cancel()
        artworkTask = nil
        actions = [:]
    }

    /// Retry failures on an explicit surface re-entry, never on each save.
    func retryMissingArtwork() {
        requestedArtwork = requestedArtwork.filter { loadedArtwork[$0.key] == $0.value }
        startArtworkIfNeeded()
    }

    func update(
        _ next: CarPlayListPresentation,
        on template: CPListTemplate,
        actions: [String: @MainActor () async -> Void]
    ) {
        self.actions = actions
        guard next != presentation else { return }
        let oldRows = Dictionary(uniqueKeysWithValues: presentation.sections.flatMap(\.rows).map { ($0.id, $0) })
        let rows = next.sections.flatMap(\.rows)
        let styles = Dictionary(rows.map { ($0.id, $0.style) }, uniquingKeysWith: { first, _ in first })
        let slotIDs = Set(Self.artworkSlots(in: rows).map(\.id))
        items = items.filter { styles[$0.key] == .standard }
        imageRows = imageRows.filter { styles[$0.key].map { $0 != .standard } ?? false }
        elements = elements.filter { slotIDs.contains($0.key) }
        images = images.filter { slotIDs.contains($0.key) }
        requestedArtwork = requestedArtwork.filter { slotIDs.contains($0.key) }
        loadedArtwork = loadedArtwork.filter { slotIDs.contains($0.key) }
        var replacedItem = false
        for row in rows {
            if row.style != .standard {
                if updateImageRow(row, old: oldRows[row.id]) { replacedItem = true }
                continue
            }
            if let item = items[row.id], let old = oldRows[row.id] {
                var fields: [String] = []
                if old.title != row.title { item.setText(row.title); fields.append("title") }
                if old.detail != row.detail { item.setDetailText(row.detail); fields.append("detail") }
                if old.isPlaying != row.isPlaying { item.isPlaying = row.isPlaying; fields.append("playing") }
                if old.isEnabled != row.isEnabled { item.isEnabled = row.isEnabled; fields.append("enabled") }
                if old.disclosure != row.disclosure {
                    item.accessoryType = row.disclosure ? .disclosureIndicator : .none
                    fields.append("accessory")
                }
                if !fields.isEmpty { record(.carPlayListMutation, "row=\(row.id) fields=\(fields.joined(separator: ","))") }
            } else {
                // A row that changed style keeps its ID but needs its new item placed.
                if oldRows[row.id] != nil { replacedItem = true }
                let item = CPListItem(text: row.title, detailText: row.detail)
                item.isEnabled = row.isEnabled
                item.isPlaying = row.isPlaying
                item.playingIndicatorLocation = .trailing
                item.accessoryType = row.disclosure ? .disclosureIndicator : .none
                item.handler = { [weak self] _, completion in
                    Task { @MainActor in
                        defer { completion() }
                        guard let self, self.items[row.id]?.isEnabled == true else { return }
                        await self.actions[row.id]?()
                    }
                }
                items[row.id] = item
            }
            if row.artwork == nil, oldRows[row.id]?.artwork != nil {
                items[row.id]?.setImage(nil)
                requestedArtwork[row.id] = nil
                loadedArtwork[row.id] = nil
                record(.carPlayArtworkUpdate, "row=\(row.id) cleared")
            }
        }
        let structureChanged = replacedItem || next.sections.count != presentation.sections.count
            || zip(next.sections, presentation.sections).contains {
                $0.id != $1.id || $0.header != $1.header || $0.rows.map(\.id) != $1.rows.map(\.id)
            }
        presentation = next
        if structureChanged {
            template.updateSections(next.sections.map { section in
                CPListSection(
                    items: section.rows.compactMap { row -> (any CPListTemplateItem)? in items[row.id] ?? imageRows[row.id] },
                    header: section.header,
                    sectionIndexTitle: nil
                )
            })
            record(.carPlayListMutation, "sections rows=\(rows.count)")
        }
        startArtworkIfNeeded()
    }

    /// Creates or refreshes a card or strip. Returns true when a new item
    /// replaced the one in the template, so sections must be rebuilt.
    private func updateImageRow(_ row: Row, old: Row?) -> Bool {
        if imageRows[row.id] != nil, old == row { return false }
        let rowElements: [CPListImageRowItemElement]
        switch row.style {
        case .standard:
            return false
        case .card:
            let card = CPListImageRowItemCardElement(
                image: images[row.id] ?? Self.placeholder, showsImageFullHeight: true,
                title: row.title, subtitle: row.detail, tintColor: nil
            )
            elements[row.id] = card
            rowElements = [card]
        case .strip(let tiles):
            rowElements = tiles.map { tile in
                let element = CPListImageRowItemRowElement(
                    image: images[tile.id] ?? Self.placeholder, title: tile.title, subtitle: tile.subtitle
                )
                elements[tile.id] = element
                return element
            }
        }
        let text: String? = if case .card = row.style { nil } else { row.title }
        if let item = imageRows[row.id], let old, Self.sameKind(old.style, row.style) {
            item.text = text
            item.isEnabled = row.isEnabled
            item.elements = rowElements
            record(.carPlayListMutation, "row=\(row.id) fields=elements")
            return false
        }
        let item: CPListImageRowItem = switch row.style {
        case .card:
            CPListImageRowItem(text: text, cardElements: rowElements.compactMap { $0 as? CPListImageRowItemCardElement },
                               allowsMultipleLines: false)
        default:
            CPListImageRowItem(text: text, elements: rowElements.compactMap { $0 as? CPListImageRowItemRowElement },
                               allowsMultipleLines: false)
        }
        item.isEnabled = row.isEnabled
        let rowID = row.id
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                defer { completion() }
                await self?.actions[rowID]?()
            }
        }
        item.listImageRowHandler = { [weak self] _, index, completion in
            Task { @MainActor in
                defer { completion() }
                guard let self, let current = self.presentation.sections.flatMap(\.rows).first(where: { $0.id == rowID }) else { return }
                switch current.style {
                case .strip(let tiles) where tiles.indices.contains(index):
                    await self.actions[tiles[index].id]?()
                default:
                    await self.actions[rowID]?()
                }
            }
        }
        imageRows[row.id] = item
        return true
    }

    private static func sameKind(_ left: Row.Style, _ right: Row.Style) -> Bool {
        switch (left, right) {
        case (.standard, .standard), (.card, .card), (.strip, .strip): true
        default: false
        }
    }

    private static let placeholder = UIImage(systemName: "music.note") ?? UIImage()

    /// Every artwork the list shows, in display order: one per standard row
    /// or card, one per strip tile.
    private static func artworkSlots(in rows: some Sequence<Row>) -> [(id: String, artwork: Row.Artwork)] {
        rows.flatMap { row -> [(id: String, artwork: Row.Artwork)] in
            switch row.style {
            case .strip(let tiles): tiles.compactMap { tile in tile.artwork.map { (tile.id, $0) } }
            default: row.artwork.map { [(row.id, $0)] } ?? []
            }
        }
    }

    private func startArtworkIfNeeded() {
        guard artworkTask == nil else { return }
        artworkTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // One request at a time, in display order, bounded by what
                // CarPlay can display. Unchanged rows never restart artwork.
                let rows = self.presentation.sections.flatMap(\.rows).prefix(CPListTemplate.maximumItemCount)
                guard let slot = Self.artworkSlots(in: rows).first(where: { self.requestedArtwork[$0.id] != $0.artwork }) else {
                    self.artworkTask = nil
                    return
                }
                self.requestedArtwork[slot.id] = slot.artwork
                let image = await self.loadArtwork(slot.artwork)
                guard !Task.isCancelled else { return }
                let allRows = self.presentation.sections.flatMap(\.rows)
                guard Self.artworkSlots(in: allRows).first(where: { $0.id == slot.id })?.artwork == slot.artwork else { continue }
                // Keep the previous image through loading and failures.
                if let image {
                    self.items[slot.id]?.setImage(image)
                    self.elements[slot.id]?.image = image
                    self.images[slot.id] = image
                    self.loadedArtwork[slot.id] = slot.artwork
                    self.record(.carPlayArtworkUpdate, "row=\(slot.id)")
                }
            }
        }
    }

    private static func loadArtwork(_ artwork: Row.Artwork) async -> UIImage? {
        switch artwork {
        case .symbol(let name, let tint):
            let image = UIImage(systemName: name)
            return tint.flatMap { image?.withTintColor($0, renderingMode: .alwaysOriginal) } ?? image
        case .track(let url, let playlistID):
            let image = await ArtworkImagePipeline.shared.image(for: url, size: 128, playlistID: playlistID, priority: .utility)
            return image.map { UIImage(cgImage: $0) }
        case .collage(let snapshot, let playlistID, let scope):
            let image = await PlaylistCollageService.shared.image(for: snapshot, playlistID: playlistID, scope: scope)
            return image.map { UIImage(cgImage: $0) }
        }
    }
}
