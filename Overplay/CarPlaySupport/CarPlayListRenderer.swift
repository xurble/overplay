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
        /// have no playing indicator of CarPlay's own.
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
            var isPlaying = false
        }
        enum Artwork: Equatable {
            case symbol(String, tint: UIColor? = nil)
            case track(url: String?, playlistID: String, size: Int = 128)
            case collage(PlaylistCollage, playlistID: String, scope: PlaylistPlaybackScope)
            /// The art with the now-playing badge over it (`CarPlayPlayingBadge`),
            /// for art CarPlay draws `displayed` points across.
            indirect case playing(Artwork, displayed: CGSize)

            /// The art without any badge.
            var plain: Artwork {
                if case .playing(let artwork, _) = self { artwork } else { self }
            }
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

    /// The art, title and shuffle button above a track list.
    struct Header: Equatable {
        var title: String
        var subtitle: String? = nil
        var artwork: Row.Artwork? = nil
        /// The action run by the header's shuffle button (Shuffle and Play).
        var shuffleActionID: String
        var canShuffle: Bool
    }

    var header: Header? = nil
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
    /// Each slot's last loaded art without the badge, to add or remove it at once.
    private var plainImages: [String: (artwork: Row.Artwork, image: UIImage)] = [:]
    private var actions: [String: @MainActor () async -> Void] = [:]
    private var requestedArtwork: [String: Row.Artwork] = [:]
    private var loadedArtwork: [String: Row.Artwork] = [:]
    private var artworkTask: Task<Void, Never>?
    /// The header art whose load has finished, loaded or not.
    private var settledHeaderArtwork: Row.Artwork?
    /// CarPlay lays out a header assigned while a push animates at the
    /// animating width, and keeps it: the title is cut to two letters. Header
    /// changes wait while a push runs.
    private var holdsHeader = false
    private var headerPending = false
    private weak var template: CPListTemplate?
    private static let headerSlotID = "listHeader"
    private let loadArtwork: @MainActor (Row.Artwork) async -> UIImage?
    private let record: (MusicKitActivityOperation, String) -> Void
    /// Whether a playing standard row's art carries the badge: only where
    /// CarPlay draws no playing indicator of its own (`CarPlayPlayingBadge`).
    private let badgesRows: Bool

    init(
        loadArtwork: @escaping @MainActor (Row.Artwork) async -> UIImage? = CarPlayListRenderer.loadArtwork,
        record: @escaping (MusicKitActivityOperation, String) -> Void = {
            MusicKitActivityLog.shared.record($0, detail: $1)
        },
        badgesRows: Bool = !CarPlayPlayingBadge.systemIndicatorShows
    ) {
        self.loadArtwork = loadArtwork
        self.record = record
        self.badgesRows = badgesRows
    }

    /// Marks the playing rows again after the player starts or stops. On
    /// iOS 27 CarPlay animates a playing row's indicator, but the root's
    /// Inbox row, marked playing when its start began, stayed still while
    /// the list it opened animated (2026-10-25). Suspected: CarPlay takes the
    /// indicator's motion from whether the app is playing when `isPlaying` is
    /// set. Setting it again once that changes brings the rows up to date.
    /// Only where CarPlay draws its own indicator: elsewhere the badge marks
    /// the row, and the two writes would do nothing but redraw it.
    func playbackStateChanged() {
        guard !badgesRows else { return }
        let playingIDs = presentation.sections.flatMap(\.rows).filter(\.isPlaying).map(\.id)
        let playing = playingIDs.compactMap { id in items[id].map { (id, $0) } }
        guard !playing.isEmpty else { return }
        playing.forEach { $0.1.isPlaying = false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Only rows that are still playing, in this renderer's list.
            let replayed = playing.filter { id, item in
                self.items[id] === item
                    && self.presentation.sections.contains { $0.rows.contains { $0.id == id && $0.isPlaying } }
            }
            replayed.forEach { $0.1.isPlaying = true }
            // Names only the rows marked again: the car check reads this line.
            guard !replayed.isEmpty else { return }
            self.record(.carPlayListMutation, "rows=\(replayed.map(\.0).joined(separator: ",")) fields=playing-replayed")
        }
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

    /// Waits, at most `timeout`, for the header's art, so a list is pushed
    /// with its final header rather than replacing it during the push.
    func headerArtwork(within timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while let artwork = presentation.header?.artwork, settledHeaderArtwork != artwork, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Holds header changes from the start of a push until it has finished.
    func holdHeaderChanges() {
        holdsHeader = true
    }

    func releaseHeaderChanges() {
        holdsHeader = false
        guard headerPending, let template else { return }
        headerPending = false
        applyHeader(on: template)
    }

    func update(
        _ next: CarPlayListPresentation,
        on template: CPListTemplate,
        actions: [String: @MainActor () async -> Void]
    ) {
        self.actions = actions
        self.template = template
        guard next != presentation else { return }
        let oldRows = Dictionary(uniqueKeysWithValues: presentation.sections.flatMap(\.rows).map { ($0.id, $0) })
        let rows = next.sections.flatMap(\.rows)
        let styles = Dictionary(rows.map { ($0.id, $0.style) }, uniquingKeysWith: { first, _ in first })
        let slotIDs = Set((Self.headerSlots(next.header) + artworkSlots(in: rows)).map(\.id))
        items = items.filter { styles[$0.key] == .standard }
        imageRows = imageRows.filter { styles[$0.key].map { $0 != .standard } ?? false }
        elements = elements.filter { slotIDs.contains($0.key) }
        images = images.filter { slotIDs.contains($0.key) }
        requestedArtwork = requestedArtwork.filter { slotIDs.contains($0.key) }
        loadedArtwork = loadedArtwork.filter { slotIDs.contains($0.key) }
        plainImages = plainImages.filter { slotIDs.contains($0.key) }
        applyBadgeChanges(artworkSlots(in: rows))
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
                // Leading: CarPlay draws the indicator over the artwork, as Music does.
                item.playingIndicatorLocation = .leading
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
        let headerChanged = next.header != presentation.header
        presentation = next
        if headerChanged { applyHeaderUnlessHeld(on: template) }
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

    /// A playing change only adds or removes the badge: drawn at once over the
    /// slot's loaded art, so a rebuilt card or strip carries the right image.
    /// In the car a strip kept its badge when the plain art arrived a moment
    /// after the rebuild (2026-10-22).
    private func applyBadgeChanges(_ slots: [(id: String, artwork: Row.Artwork)]) {
        for slot in slots where requestedArtwork[slot.id] != slot.artwork {
            guard let plain = plainImages[slot.id], plain.artwork == slot.artwork.plain else { continue }
            let image = if case .playing(_, let displayed) = slot.artwork {
                CarPlayPlayingBadge.image(over: plain.image, displayed: displayed)
            } else {
                plain.image
            }
            requestedArtwork[slot.id] = slot.artwork
            loadedArtwork[slot.id] = slot.artwork
            images[slot.id] = image
            items[slot.id]?.setImage(image)
        }
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
            // A rounded square inside the card, not a crop filling it.
            // CarPlay places the square; it can't be centred.
            let card = CPListImageRowItemCardElement(
                image: images[row.id] ?? Self.placeholder, showsImageFullHeight: false,
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

    private func applyHeaderUnlessHeld(on template: CPListTemplate) {
        guard !holdsHeader else {
            headerPending = true
            return
        }
        applyHeader(on: template)
    }

    /// Builds the list header afresh: CarPlay updates it on assignment.
    private func applyHeader(on template: CPListTemplate) {
        guard let header = presentation.header else {
            if template.listHeader != nil {
                template.listHeader = nil
                record(.carPlayListMutation, "header cleared")
            }
            return
        }
        let actionID = header.shuffleActionID
        // Icon only: a title squeezes the button beside the art.
        let shuffle = CPButton(image: UIImage(systemName: "shuffle") ?? UIImage()) { [weak self] _ in
            Task { @MainActor in await self?.actions[actionID]?() }
        }
        shuffle.isEnabled = header.canShuffle
        let details = CPListTemplateDetailsHeader(
            thumbnail: CPThumbnailImage(image: images[Self.headerSlotID] ?? Self.placeholder),
            title: header.title, subtitle: header.subtitle, actionButtons: [shuffle]
        )
        details.wantsAdaptiveBackgroundStyle = true
        template.listHeader = details
        record(.carPlayListMutation, "header")
    }

    private static func headerSlots(_ header: CarPlayListPresentation.Header?) -> [(id: String, artwork: Row.Artwork)] {
        header?.artwork.map { [(headerSlotID, $0)] } ?? []
    }

    /// Every artwork the list shows, in display order: one per standard row
    /// or card, one per strip tile. Playing art carries the badge, on a
    /// standard row only when `badgesRows`; a playing symbol row changes its
    /// symbol instead.
    private func artworkSlots(in rows: some Sequence<Row>) -> [(id: String, artwork: Row.Artwork)] {
        let badgesRows = badgesRows
        func slot(_ artwork: Row.Artwork, playing: Bool, displayed: CGSize) -> Row.Artwork {
            if case .symbol = artwork { return artwork }
            return playing ? .playing(artwork, displayed: displayed) : artwork
        }
        return rows.flatMap { row -> [(id: String, artwork: Row.Artwork)] in
            switch row.style {
            case .strip(let tiles):
                tiles.compactMap { tile in
                    tile.artwork.map { (tile.id, slot($0, playing: tile.isPlaying,
                                                      displayed: CPListImageRowItemRowElement.maximumImageSize)) }
                }
            case .card:
                row.artwork.map { [(row.id, slot($0, playing: row.isPlaying,
                                               displayed: CPListImageRowItemCardElement.maximumImageSize))] } ?? []
            case .standard:
                row.artwork.map { [(row.id, slot($0, playing: row.isPlaying && badgesRows,
                                               displayed: CPListItem.maximumImageSize))] } ?? []
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
                let header = Self.headerSlots(self.presentation.header)
                guard let slot = (header + self.artworkSlots(in: rows)).first(where: { self.requestedArtwork[$0.id] != $0.artwork }) else {
                    self.artworkTask = nil
                    return
                }
                self.requestedArtwork[slot.id] = slot.artwork
                let plain = await self.loadArtwork(slot.artwork.plain)
                let image: UIImage? = if case .playing(_, let displayed) = slot.artwork {
                    CarPlayPlayingBadge.image(over: plain, displayed: displayed)
                } else {
                    plain
                }
                guard !Task.isCancelled else { return }
                let allRows = self.presentation.sections.flatMap(\.rows)
                let current = Self.headerSlots(self.presentation.header) + self.artworkSlots(in: allRows)
                guard current.first(where: { $0.id == slot.id })?.artwork == slot.artwork else { continue }
                if let plain { self.plainImages[slot.id] = (slot.artwork.plain, plain) }
                // Keep the previous image through loading and failures.
                if slot.id == Self.headerSlotID { self.settledHeaderArtwork = slot.artwork }
                if let image, slot.id == Self.headerSlotID {
                    self.images[slot.id] = image
                    self.loadedArtwork[slot.id] = slot.artwork
                    if let template = self.template { self.applyHeaderUnlessHeld(on: template) }
                } else if let image {
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
            return CarPlayListSymbolImage.image(systemName: name, color: tint ?? .label,
                                                fraction: CarPlayListSymbolImage.rowSymbolFraction)
        case .track(let url, let playlistID, let size):
            let image = await ArtworkImagePipeline.shared.image(for: url, size: size, playlistID: playlistID, priority: .utility)
            return image.map { UIImage(cgImage: $0) }
        case .collage(let snapshot, let playlistID, let scope):
            let image = await PlaylistCollageService.shared.image(for: snapshot, playlistID: playlistID, scope: scope)
            return image.map { UIImage(cgImage: $0) }
        case .playing(let artwork, _):
            // The renderer draws the badge over whatever this loads.
            return await loadArtwork(artwork)
        }
    }
}

/// The iPhone's now-playing badge, a white arrow in a green circle at the
/// art's bottom-trailing corner. On iOS 26 CarPlay drew no indicator of its
/// own for `isPlaying` rows in the car (2026-10-21), perhaps because
/// Overplay's audio comes from Apple's music service rather than the app, so
/// every playing art carries the badge. On iOS 27 CarPlay animates its own
/// indicator over a standard row's art (2026-10-25), so those rows show that
/// instead; cards and strip tiles have no indicator of CarPlay's and keep
/// the badge. Symbol rows show playing in the symbol, as on the phone
/// dashboard.
enum CarPlayPlayingBadge {
    /// Whether CarPlay draws its own playing indicator on a standard row.
    static var systemIndicatorShows: Bool {
        if #available(iOS 27.0, *) { true } else { false }
    }

    /// The circle's diameter as a fraction of a list row's art: a little
    /// larger than on the phone, to read at a glance in the car.
    static let diameter: CGFloat = 0.38
    /// Kept clear of the corner CarPlay may round off.
    static let inset: CGFloat = 0.04

    /// The circle in art of `size` that CarPlay draws `displayed` points
    /// across: on larger art, such as a Deep Dive tile, it is as large on
    /// screen as on a row's art, not larger.
    static func circle(in size: CGSize, displayed: CGSize = CPListItem.maximumImageSize) -> CGRect {
        let row = CPListItem.maximumImageSize
        let shown = min(displayed.width, displayed.height)
        let scale = shown > 0 ? min(1, min(row.width, row.height) / shown) : 1
        let side = min(size.width, size.height) * scale
        let diameter = side * diameter, inset = side * inset
        return CGRect(x: size.width - inset - diameter, y: size.height - inset - diameter,
                      width: diameter, height: diameter)
    }

    static func image(over art: UIImage?, displayed: CGSize = CPListItem.maximumImageSize) -> UIImage {
        let size = art?.size ?? CPListItem.maximumImageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = art?.scale ?? CarPlayListSymbolImage.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let bounds = CGRect(origin: .zero, size: size)
            if let art {
                art.draw(in: bounds)
            } else {
                UIColor.darkGray.setFill()
                UIBezierPath(roundedRect: bounds, cornerRadius: min(size.width, size.height) * 0.15).fill()
            }
            let circle = circle(in: size, displayed: displayed)
            let path = UIBezierPath(ovalIn: circle)
            UIColor.systemGreen.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).setFill()
            path.fill()
            // The phone's badge is Liquid Glass; a bitmap can only suggest it:
            // a sheen across the top half and a fine light rim.
            if let context = UIGraphicsGetCurrentContext(),
               let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [UIColor.white.withAlphaComponent(0.38).cgColor,
                                               UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, 1]) {
                context.saveGState()
                path.addClip()
                context.drawLinearGradient(sheen, start: CGPoint(x: circle.midX, y: circle.minY),
                                           end: CGPoint(x: circle.midX, y: circle.midY), options: [])
                context.restoreGState()
            }
            UIColor.white.withAlphaComponent(0.45).setStroke()
            let rim = UIBezierPath(ovalIn: circle.insetBy(dx: circle.width * 0.025, dy: circle.width * 0.025))
            rim.lineWidth = circle.width * 0.05
            rim.stroke()
            let weight = UIImage.SymbolConfiguration(weight: .heavy)
            guard let arrow = UIImage(systemName: "arrow.right", withConfiguration: weight)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal),
                  arrow.size.width > 0, arrow.size.height > 0 else { return }
            let fit = circle.width * 0.5 / max(arrow.size.width, arrow.size.height)
            let glyph = CGSize(width: arrow.size.width * fit, height: arrow.size.height * fit)
            arrow.draw(in: CGRect(x: circle.midX - glyph.width / 2, y: circle.midY - glyph.height / 2,
                                  width: glyph.width, height: glyph.height))
        }
    }
}

/// A symbol for a CarPlay list row. CarPlay draws list images as given, never
/// as templates, so a bare symbol shows black on the dark list. The symbol is
/// drawn in its colour once for light and once for dark, and CarPlay picks
/// between them as its own appearance changes, whatever the phone's.
enum CarPlayListSymbolImage {
    /// Car screens are at most 3x; a sharper bitmap only scales down.
    static let scale: CGFloat = 3

    /// How much of a list row's image slot a row symbol fills. CarPlay sizes
    /// the slot for art, and a symbol filling it dwarfed the row's text; on
    /// the phone a row icon is about the size of its title.
    static let rowSymbolFraction: CGFloat = 0.55

    /// `fraction` < 1 draws the symbol that much of `size`, centred in a clear
    /// image of the whole `size`, so CarPlay does not scale it back up.
    static func image(systemName: String, color: UIColor, size: CGSize = CPListItem.maximumImageSize,
                      fraction: CGFloat = 1) -> UIImage? {
        guard let symbol = UIImage(systemName: systemName), symbol.size.width > 0, symbol.size.height > 0 else { return nil }
        let fit = min(size.width / symbol.size.width, size.height / symbol.size.height) * fraction
        let glyph = CGSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        let fitted = fraction < 1 ? size : glyph
        let frame = CGRect(x: (fitted.width - glyph.width) / 2, y: (fitted.height - glyph.height) / 2,
                           width: glyph.width, height: glyph.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            // Registered with its scale too, or the asset hands back the
            // bitmap as a 1x image three times too large.
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: style), UITraitCollection(displayScale: scale),
            ])
            let tinted = symbol.withTintColor(color.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
            let image = UIGraphicsImageRenderer(size: fitted, format: format).image { _ in
                tinted.draw(in: frame)
            }
            asset.register(image, with: traits)
        }
        return asset.image(with: UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark), UITraitCollection(displayScale: scale),
        ]))
    }
}
