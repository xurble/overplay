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
        enum Artwork: Equatable {
            case symbol(String)
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
        let ids = Set(rows.map(\.id))
        items = items.filter { ids.contains($0.key) }
        requestedArtwork = requestedArtwork.filter { ids.contains($0.key) }
        loadedArtwork = loadedArtwork.filter { ids.contains($0.key) }
        for row in rows {
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
        let structureChanged = next.sections.count != presentation.sections.count
            || zip(next.sections, presentation.sections).contains {
                $0.id != $1.id || $0.header != $1.header || $0.rows.map(\.id) != $1.rows.map(\.id)
            }
        presentation = next
        if structureChanged {
            template.updateSections(next.sections.map { section in
                CPListSection(items: section.rows.compactMap { items[$0.id] }, header: section.header, sectionIndexTitle: nil)
            })
            record(.carPlayListMutation, "sections rows=\(rows.count)")
        }
        startArtworkIfNeeded()
    }

    private func startArtworkIfNeeded() {
        guard artworkTask == nil else { return }
        artworkTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // One request at a time, in display order, bounded by what
                // CarPlay can display. Unchanged rows never restart artwork.
                guard let row = self.presentation.sections.flatMap(\.rows)
                    .prefix(CPListTemplate.maximumItemCount)
                    .first(where: { $0.artwork != nil && self.requestedArtwork[$0.id] != $0.artwork }),
                      let artwork = row.artwork else {
                    self.artworkTask = nil
                    return
                }
                self.requestedArtwork[row.id] = artwork
                let image = await self.loadArtwork(artwork)
                guard !Task.isCancelled else { return }
                guard self.presentation.sections.flatMap(\.rows).first(where: { $0.id == row.id })?.artwork == artwork else { continue }
                // Keep the previous image through loading and failures.
                if let image {
                    self.items[row.id]?.setImage(image)
                    self.loadedArtwork[row.id] = artwork
                    self.record(.carPlayArtworkUpdate, "row=\(row.id)")
                }
            }
        }
    }

    private static func loadArtwork(_ artwork: Row.Artwork) async -> UIImage? {
        switch artwork {
        case .symbol(let name): return UIImage(systemName: name)
        case .track(let url, let playlistID):
            let image = await ArtworkImagePipeline.shared.image(for: url, size: 128, playlistID: playlistID, priority: .utility)
            return image.map { UIImage(cgImage: $0) }
        case .collage(let snapshot, let playlistID, let scope):
            let image = await PlaylistCollageService.shared.image(for: snapshot, playlistID: playlistID, scope: scope)
            return image.map { UIImage(cgImage: $0) }
        }
    }
}
