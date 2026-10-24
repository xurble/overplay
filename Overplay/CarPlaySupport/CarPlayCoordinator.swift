import CarPlay
import Foundation
import Observation
import SwiftData
import UIKit

@MainActor
enum CarPlayListTemplateUpdater {
    static func refreshTarget(
        topTemplate: CPTemplate?,
        templateStack: [CPTemplate]
    ) -> CPListTemplate? {
        (topTemplate as? CPListTemplate)
            ?? templateStack.reversed().compactMap { $0 as? CPListTemplate }.first
    }

    @discardableResult
    static func update(
        _ template: CPListTemplate,
        sections: [CPListSection]
    ) -> CPListTemplate {
        template.updateSections(sections)
        return template
    }
}

@MainActor
enum CarPlayNowPlayingButtonImageFactory {
    private static let preferredPointSize: CGFloat = 24
    /// One step heavier than `.light`, which read as too thin in the car (#50).
    static let symbolWeight: UIImage.SymbolWeight = .regular

    static func image(
        systemName: String,
        traitCollection: UITraitCollection,
        maximumSize: CGSize = CPNowPlayingButtonMaximumImageSize
    ) -> UIImage? {
        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: preferredPointSize,
            weight: symbolWeight
        )
        guard let symbol = UIImage(systemName: systemName, compatibleWith: traitCollection)?
            .applyingSymbolConfiguration(symbolConfiguration) else {
            return nil
        }

        let fittedSize = fittedSize(for: symbol.size, maximumSize: maximumSize)
        guard fittedSize.width > 0, fittedSize.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat(for: traitCollection)
        format.scale = max(traitCollection.displayScale, 1)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: fittedSize, format: format)
        let monochromeSymbol = symbol.withTintColor(.black, renderingMode: .alwaysOriginal)
        return renderer.image { _ in
            monochromeSymbol.draw(in: CGRect(origin: .zero, size: fittedSize))
        }
        .withRenderingMode(.alwaysTemplate)
    }

    private static func fittedSize(for size: CGSize, maximumSize: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0,
              maximumSize.width > 0, maximumSize.height > 0 else {
            return .zero
        }

        let scale = min(1, maximumSize.width / size.width, maximumSize.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

@MainActor
final class CarPlayCoordinator: NSObject {
    private weak var interfaceController: CPInterfaceController?
    private var playbackController: PlaybackController?
    private weak var runtime: AppRuntime?
    private var modelContext: ModelContext?
    private var refreshTask: Task<Void, Never>?
    private var rootRenderer = CarPlayListRenderer()
    private var playlistRenderer = CarPlayListRenderer()
    private var libraryRefreshTask: Task<Void, Never>?
    private var playbackObservationGeneration = 0
    private var lastNowPlayingButtonSignature: CarPlayNowPlayingButtonSignature?
    private var lastNowPlayingContext: PlaylistPlaybackContext?
    private var displayedActions: [CarPlayNowPlayingAction] = []
    private var displayedActionButtons: [CPNowPlayingButton] = []
    private var visiblePlaylistID: UUID?
    // Held by identity rather than title: two playlists can share a name, and
    // a playlist can be called "Overplay".
    private weak var rootListTemplate: CPListTemplate?
    private weak var visiblePlaylistTemplate: CPListTemplate?
    // Recents (`PLAY-019`): the list of albums and artists, and the one open.
    private var recentsRenderer = CarPlayListRenderer()
    private var recentRenderer = CarPlayListRenderer()
    private weak var recentsTemplate: CPListTemplate?
    private weak var visibleRecentTemplate: CPListTemplate?
    private var visibleRecentID: UUID?
    // Library (`LIB-001`): a category's list, and the collection open from it.
    private var libraryCategoryRenderer = CarPlayListRenderer()
    private var libraryItemRenderer = CarPlayListRenderer()
    private weak var libraryCategoryTemplate: CPListTemplate?
    private var visibleLibraryCategory: LibraryBrowser.Category?
    private weak var libraryItemTemplate: CPListTemplate?
    private var visibleLibraryItem: LibraryBrowser.Item?
    private var visibleLibraryEntries: [LibraryBrowser.Entry] = []
    private var libraryItemPlaceholder: String?
    /// The failure kind last alerted in this episode; nil when none is active.
    private var alertedFailureKind: PlaybackFailure.Kind?
    private weak var failureAlert: CPAlertTemplate?
    /// Shows the failure alert once its grace period ends.
    private var failureAlertCheck: Task<Void, Never>?
    private var libraryChangeObserver: NSObjectProtocol?
    // Shuffle and repeat are player modes; they work before the library is restored.
    private lazy var shuffleButton = CPNowPlayingShuffleButton { [weak self] _ in
        Task { @MainActor in
            guard let self, let modelContext = self.modelContext else { return }
            await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                await self.playbackController?.toggleShuffle(context: modelContext)
            }
        }
    }
    private lazy var repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
        Task { @MainActor in
            guard let self, let modelContext = self.modelContext else { return }
            await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                await self.playbackController?.toggleRepeatAll(context: modelContext)
            }
        }
    }

    func connect(interfaceController: CPInterfaceController, runtime: AppRuntime) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        self.runtime = runtime
        playbackController = runtime.playbackController
        modelContext = runtime.mainModelContext


        configureNowPlayingTemplate()
        startPlaybackObservation()
        startLibraryChangeObservation()
        if runtime.libraryRestoration.isReady, let modelContext { try? PlaylistCollageService.prepareSnapshots(in: modelContext) }
        setRootTemplate(animated: false)

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if let context = runtime.mainModelContext {
                await runtime.startupViewModel.bootstrap(
                    isReady: runtime.authorizationService.readiness.isReady,
                    dependencies: runtime.startupViewModel.dependencies(modelContext: context, runtime: runtime,
                        authorizationService: runtime.authorizationService, playbackController: runtime.playbackController)
                )
                await runtime.startupViewModel.authorizedServicesTask?.value
            }
            guard !Task.isCancelled else { return }
            self?.refreshVisibleTemplate()
        }
    }

    func disconnect() {
        isPlacingPlayingPlaylist = false
        rootRenderer.stop()
        playlistRenderer.stop()
        recentsRenderer.stop()
        recentRenderer.stop()
        libraryRefreshTask?.cancel()
        libraryRefreshTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        stopPlaybackObservation()
        stopLibraryChangeObservation()

        interfaceController = nil
        runtime = nil
        modelContext = nil
        playbackController = nil
        visiblePlaylistID = nil
        rootListTemplate = nil
        visiblePlaylistTemplate = nil
        recentsTemplate = nil
        visibleRecentTemplate = nil
        visibleRecentID = nil
        lastNowPlayingButtonSignature = nil
        lastNowPlayingContext = nil
        displayedActions = []
        displayedActionButtons = []
        CPNowPlayingTemplate.shared.remove(self)
    }

    private func setRootTemplate(animated: Bool) {
        guard let interfaceController else { return }
        playlistRenderer.stop()
        visiblePlaylistID = nil
        visiblePlaylistTemplate = nil
        recentsRenderer.stop()
        recentRenderer.stop()
        recentsTemplate = nil
        visibleRecentTemplate = nil
        visibleRecentID = nil
        rootRenderer.stop()
        rootRenderer = CarPlayListRenderer()
        let template = CPListTemplate(title: "Overplay", sections: [])
        updateRootList(template)
        rootListTemplate = template
        interfaceController.setRootTemplate(template, animated: animated, completion: nil)
    }

    private func updateRootList(_ template: CPListTemplate) {
        guard runtime?.libraryRestoration.isReady == true else {
            // Playback does not wait for restoration: offer the saved intent.
            var rows: [CarPlayListPresentation.Row] = []
            var actions: [String: @MainActor () async -> Void] = [:]
            if let current = playbackController?.currentTrack, playbackController?.intent != nil {
                rows.append(.init(id: "resume", title: "Resume", detail: "\(current.title) — \(current.artistName)"))
                actions["resume"] = { [weak self] in await self?.resumeBeforeRestoration() }
            }
            rows.append(.init(id: "restoring", title: "Restoring your library",
                              detail: "Open Overplay on iPhone to check iCloud restoration.", isEnabled: false))
            rootRenderer.update(.init(sections: [.init(id: "restoring", rows: rows)]), on: template, actions: actions)
            return
        }
        typealias Section = CarPlayListPresentation.Section
        typealias Row = CarPlayListPresentation.Row
        var sections: [Section] = []
        var actions: [String: @MainActor () async -> Void] = [:]
        func row(_ summary: PlaylistSummaryPresentation) -> Row {
            let id = summary.playbackScope.playbackOrderPlaylistID(for: summary.id.uuidString)
            actions[id] = { [weak self] in await self?.showPlaylist(summary) }
            let playlist = modelContext.flatMap { try? PlaylistRepository.playlist(id: summary.id, in: $0) }
            let artwork = playlist.flatMap { PlaylistCollageService.snapshot(for: $0, scope: summary.playbackScope) }
            return Row(id: id, title: summary.title, detail: summary.playableTrackCountLabel,
                isPlaying: isCurrentPlaylist(summary), disclosure: true,
                artwork: artwork.map { .collage($0, playlistID: summary.musicPlaylistID ?? "", scope: summary.playbackScope) })
        }
        do {
            let summaries = try playlistSummaries()
            // The One True Playlist leads as a large artwork card, as on the phone.
            // Cards have no CarPlay playing indicator: the art carries the
            // phone's now-playing badge and the subtitle says so.
            if let main = summaries.first(where: { $0.role == .oneTruePlaylist }) {
                var mainRow = row(main)
                mainRow.style = .card
                mainRow.detail = mainRow.isPlaying ? "Now Playing" : nil
                sections.append(Section(id: "main", rows: [mainRow]))
            }
            // Triage and a compact Retired row share one headerless section, as on the phone dashboard.
            var triageRows: [Row] = []
            if let triage = summaries.first(where: { $0.role == .triageBucket && $0.playbackScope == .active }) {
                var triageRow = row(triage)
                triageRow.detail = triage.triageDetail(sourceCount: triageSourceCount())
                // The inbox icon, not artwork, coloured as on the phone dashboard:
                // green while Triage plays.
                triageRow.artwork = .symbol("tray.fill", tint: triageRow.isPlaying ? .systemGreen : .systemTeal)
                triageRows.append(triageRow)
            }
            if let retired = summaries.first(where: { $0.playbackScope == .retired }) {
                var retiredRow = row(retired)
                retiredRow.detail = nil
                // As on the phone dashboard: a green play symbol while Retired plays.
                retiredRow.artwork = retiredRow.isPlaying
                    ? .symbol("play.fill", tint: .systemGreen) : .symbol("archivebox.fill", tint: .systemGray)
                triageRows.append(retiredRow)
            }
            if !triageRows.isEmpty { sections.append(Section(id: "triage", rows: triageRows)) }
            // Recent Deep Dives (`PLAY-019`): a strip of artwork tiles, as on the
            // phone. A tile opens that album or artist; the title opens the list.
            if let modelContext, let playbackController,
               let recents = try? RecentCollectionRepository.recents(in: modelContext), !recents.isEmpty {
                actions["recents"] = { [weak self] in self?.showRecents() }
                let tiles = recents.map { recent -> Row.Tile in
                    let recentID = recent.id
                    let tileID = "recent-tile-\(recent.groupKey)"
                    actions[tileID] = { [weak self] in await self?.showRecent(recentID) }
                    let isPlaying = RecentCollectionPresentation.isPlaying(recent, controller: playbackController)
                    return Row.Tile(
                        id: tileID, title: recent.title,
                        subtitle: isPlaying ? "Now Playing" : RecentCollectionPresentation.subtitle(for: recent),
                        artwork: .track(url: recent.artworkURLTemplate, playlistID: recent.collection.reservedPlaylistID),
                        isPlaying: isPlaying
                    )
                }
                sections.append(Section(id: "recents", rows: [Row(
                    id: "recents", title: "Recent Deep Dives", style: .strip(tiles)
                )]))
            }
            if sections.isEmpty {
                sections = [Section(id: "empty", rows: [Row(id: "empty", title: "No linked playlists",
                    detail: "Open Overplay on iPhone to choose playlists.", isEnabled: false)])]
            }
            // The Apple Music library by category, as on the phone, without
            // Songs (`LIB-001`).
            let libraryRows = Self.libraryCategories.map { category -> Row in
                let id = "library-\(category.id)"
                actions[id] = { [weak self] in self?.showLibraryCategory(category) }
                return Row(id: id, title: category.rawValue, disclosure: true, artwork: .symbol(category.systemImage))
            }
            sections.append(Section(id: "library", header: "Library", rows: libraryRows))
        } catch {
            // A failed read is not evidence that the displayed library vanished.
            guard rootRenderer.presentation.sections.isEmpty else { return }
            sections = [Section(id: "error", rows: [Row(id: "error", title: "Could not load playlists",
                detail: UserFacingError.message(for: error), isEnabled: false)])]
        }
        rootRenderer.update(.init(sections: sections), on: template, actions: actions)
    }

    /// Shuffle and resume report failure through the controller rather than by
    /// throwing, so surface it instead of navigating to a stale player.
    private func showPlaybackFailure(title: String) {
        showError(
            title: title,
            message: playbackController?.statusMessage ?? "Apple Music playback could not start."
        )
    }

    private func triageSourceCount() -> Int {
        guard let modelContext, let playlists = try? PlaylistRepository.activePlaylists(in: modelContext) else { return 0 }
        return playlists.filter { $0.role == .triageSource }.count
    }

    // MARK: - Library (`LIB-001`)

    private static let libraryCategories: [LibraryBrowser.Category] = [.playlists, .artists, .albums]

    private func showLibraryCategory(_ category: LibraryBrowser.Category) {
        guard runtime?.libraryRestoration.isReady == true, let interfaceController else { return }
        libraryCategoryRenderer.stop()
        libraryCategoryRenderer = CarPlayListRenderer()
        let template = CPListTemplate(title: category.rawValue, sections: [])
        libraryCategoryTemplate = template
        visibleLibraryCategory = category
        updateLibraryCategoryList(template)
        observeLibraryCache(template, category: category)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { await LibraryCache.shared.prepare(category) }
    }

    /// The list follows the cache as it loads or refreshes, while it is open.
    private func observeLibraryCache(_ template: CPListTemplate, category: LibraryBrowser.Category) {
        let cache = LibraryCache.shared
        withObservationTracking {
            _ = cache.items[category]
            _ = cache.failures[category]
            _ = cache.refreshing
        } onChange: { [weak self, weak template] in
            Task { @MainActor [weak self, weak template] in
                guard let self, let template, self.libraryCategoryTemplate === template else { return }
                self.updateLibraryCategoryList(template)
                self.observeLibraryCache(template, category: category)
            }
        }
    }

    private func updateLibraryCategoryList(_ template: CPListTemplate) {
        guard let category = visibleLibraryCategory, let playbackController else { return }
        typealias Row = CarPlayListPresentation.Row
        let cache = LibraryCache.shared
        var actions: [String: @MainActor () async -> Void] = [:]
        let items = cache.items[category] ?? []
        let rows = items.prefix(CPListTemplate.maximumItemCount).map { item -> Row in
            actions[item.id] = { [weak self] in await self?.showLibraryItem(item) }
            return Row(id: item.id, title: item.title, detail: item.subtitle,
                isPlaying: playbackController.currentTrack != nil
                    && playbackController.playingCollectionGroupKey == item.collection.groupKey,
                disclosure: true,
                artwork: .track(url: item.artworkURL, playlistID: ArtworkCacheService.libraryPlaylistID))
        }
        let message: String = if let failure = cache.failures[category] {
            "Couldn't load your \(category.rawValue.lowercased()): \(failure)"
        } else if !cache.hasContent(category) || cache.refreshing.contains(category) {
            "Loading…"
        } else {
            "No \(category.rawValue.lowercased()) in your library."
        }
        libraryCategoryRenderer.update(.init(sections: [.init(id: "items", rows: rows.isEmpty
            ? [Row(id: "empty", title: message, isEnabled: false)] : rows)]), on: template, actions: actions)
    }

    /// Loads the songs first, so the list opens filled; the tapped row shows
    /// CarPlay's spinner meanwhile.
    private func showLibraryItem(_ item: LibraryBrowser.Item) async {
        guard runtime?.libraryRestoration.isReady == true else { return }
        libraryItemRenderer.stop()
        libraryItemRenderer = CarPlayListRenderer()
        let template = CPListTemplate(title: item.title, sections: [])
        libraryItemTemplate = template
        visibleLibraryItem = item
        visibleLibraryEntries = []
        libraryItemPlaceholder = "Loading…"
        do {
            let entries = try await LibraryBrowser.songs(in: item)
            guard libraryItemTemplate === template else { return }
            visibleLibraryEntries = entries
            libraryItemPlaceholder = entries.isEmpty ? "No songs Overplay can play." : nil
        } catch {
            guard libraryItemTemplate === template else { return }
            libraryItemPlaceholder = "Couldn't load the songs: \(UserFacingError.message(for: error))"
        }
        updateLibraryItemList(template)
        await pushList(template, renderer: libraryItemRenderer) { [weak self] in self?.libraryItemTemplate === template }
    }

    /// Shuffle and Play, then the songs, like a Recent Deep Dive.
    private func updateLibraryItemList(_ template: CPListTemplate) {
        guard let item = visibleLibraryItem, let modelContext, let playbackController else { return }
        typealias Row = CarPlayListPresentation.Row
        let groupKey = item.collection.groupKey
        var actions: [String: @MainActor () async -> Void] = [
            "shuffle": { [weak self] in await self?.playLibraryItem(startingAt: nil) }
        ]
        let songs = RecentCollectionPresentation.songs(visibleLibraryEntries.map(\.song), rowID: Self.libraryRowID, in: modelContext)
        let rows: [Row] = songs.prefix(max(0, CPListTemplate.maximumItemCount - 1)).map { song in
            actions[song.catalogID] = { [weak self] in await self?.playLibraryItem(startingAt: song.catalogID) }
            return Row(id: song.catalogID, title: song.summary.title, detail: song.summary.detailText,
                isPlaying: RecentCollectionPresentation.isCurrent(song, groupKey: groupKey, controller: playbackController),
                artwork: .track(url: song.summary.artworkURLString, playlistID: ArtworkCacheService.libraryPlaylistID))
        }
        let header = CarPlayListPresentation.Header(
            title: item.title,
            subtitle: "\(item.kindName) · \(PlaylistSummaryPresentation.trackCountLabel(songs.count))",
            artwork: .track(url: item.artworkURL, playlistID: ArtworkCacheService.libraryPlaylistID, size: 512),
            shuffleActionID: "shuffle",
            canShuffle: !rows.isEmpty
        )
        libraryItemRenderer.update(.init(header: header, sections: [
            .init(id: "tracks", rows: rows.isEmpty
                ? [Row(id: "empty", title: libraryItemPlaceholder ?? "No songs Overplay can play.", isEnabled: false)] : rows)
        ]), on: template, actions: actions)
    }

    /// The shared Library action (`LIB-001`, `SURFACE-003`); CarPlay only
    /// presents the outcome.
    private func playLibraryItem(startingAt catalogSongID: String?) async {
        guard let item = visibleLibraryItem, let playbackController, let modelContext else { return }
        let entries = visibleLibraryEntries
        let started = await MusicKitActivityLog.shared.withOrigin(.carPlay) {
            await LibraryBrowser.play(item, entries: entries, startingAt: catalogSongID,
                                      controller: playbackController, context: modelContext)
        }
        refreshAfterTrackAction()
        if started {
            showNowPlaying()
        } else if playbackController.playbackFailure == nil {
            showPlaybackFailure(title: "Playback failed")
        }
    }

    /// Library songs have no Overplay row of their own, as on the phone.
    private static let libraryRowID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: - Recents (`PLAY-019`)

    private func showRecents() {
        guard runtime?.libraryRestoration.isReady == true, let interfaceController else { return }
        interfaceController.pushTemplate(makeRecentsTemplate(), animated: true, completion: nil)
    }

    private func makeRecentsTemplate() -> CPListTemplate {
        recentsRenderer.stop()
        recentsRenderer = CarPlayListRenderer()
        let template = CPListTemplate(title: "Recent Deep Dives", sections: [])
        updateRecentsList(template)
        recentsTemplate = template
        return template
    }

    private func updateRecentsList(_ template: CPListTemplate) {
        guard let modelContext, let playbackController else { return }
        typealias Row = CarPlayListPresentation.Row
        var actions: [String: @MainActor () async -> Void] = [:]
        let recents = (try? RecentCollectionRepository.recents(in: modelContext)) ?? []
        let rows = recents.map { recent -> Row in
            let recentID = recent.id
            actions[recent.groupKey] = { [weak self] in await self?.showRecent(recentID) }
            return Row(id: recent.groupKey, title: recent.title, detail: RecentCollectionPresentation.subtitle(for: recent),
                isPlaying: RecentCollectionPresentation.isPlaying(recent, controller: playbackController), disclosure: true,
                artwork: .track(url: recent.artworkURLTemplate, playlistID: recent.collection.reservedPlaylistID))
        }
        recentsRenderer.update(.init(sections: [.init(id: "recents", rows: rows.isEmpty
            ? [Row(id: "empty", title: "No recent albums or artists", isEnabled: false)] : rows)]),
            on: template, actions: actions)
    }

    private func showRecent(_ id: UUID) async {
        guard runtime?.libraryRestoration.isReady == true, let modelContext,
              let recent = try? RecentCollectionRepository.recent(id: id, in: modelContext) else {
            refreshLibraryLists()
            return
        }
        let template = makeRecentTemplate(recent)
        await pushList(template, renderer: recentRenderer) { [weak self] in self?.visibleRecentTemplate === template }
    }

    /// Pushes a track list once its header art is in (or after a short wait),
    /// and holds header changes until the push has finished, so CarPlay never
    /// lays the header out mid-animation. The tapped row shows CarPlay's
    /// spinner meanwhile. A list replaced while waiting is not pushed.
    private func pushList(_ template: CPListTemplate, renderer: CarPlayListRenderer,
                          isCurrent: () -> Bool) async {
        await renderer.headerArtwork(within: .milliseconds(500))
        guard let interfaceController, isCurrent() else { return }
        renderer.holdHeaderChanges()
        interfaceController.pushTemplate(template, animated: true) { _, _ in
            Task { @MainActor in renderer.releaseHeaderChanges() }
        }
    }

    private func makeRecentTemplate(_ recent: RecentCollectionRecord) -> CPListTemplate {
        recentRenderer.stop()
        recentRenderer = CarPlayListRenderer()
        let template = CPListTemplate(title: recent.title, sections: [])
        visibleRecentID = recent.id
        updateRecentList(template, recent: recent)
        visibleRecentTemplate = template
        return template
    }

    /// Shuffle and Play, then the saved songs, like a playlist's list.
    private func updateRecentList(_ template: CPListTemplate, recent: RecentCollectionRecord) {
        guard let modelContext, let playbackController else { return }
        typealias Row = CarPlayListPresentation.Row
        let recentID = recent.id
        let playlistID = recent.collection.reservedPlaylistID
        var actions: [String: @MainActor () async -> Void] = [
            "shuffle": { [weak self] in await self?.playRecent(recentID, startingAt: nil) }
        ]
        let songs = RecentCollectionPresentation.songs(for: recent, in: modelContext)
        let rows: [Row] = songs.prefix(max(0, CPListTemplate.maximumItemCount - 1)).map { song in
            actions[song.catalogID] = { [weak self] in await self?.playRecent(recentID, startingAt: song.catalogID) }
            return Row(id: song.catalogID, title: song.summary.title, detail: song.summary.detailText,
                isPlaying: RecentCollectionPresentation.isCurrent(song, in: recent, controller: playbackController),
                artwork: .track(url: song.summary.artworkURLString, playlistID: playlistID))
        }
        let header = CarPlayListPresentation.Header(
            title: recent.title,
            subtitle: PlaylistSummaryPresentation.trackCountLabel(songs.count),
            artwork: .track(url: recent.artworkURLTemplate, playlistID: playlistID, size: 512),
            shuffleActionID: "shuffle",
            canShuffle: !rows.isEmpty
        )
        recentRenderer.update(.init(header: header, sections: [
            .init(id: "tracks", rows: rows.isEmpty
                ? [Row(id: "empty", title: "No songs saved", isEnabled: false)] : rows)
        ]), on: template, actions: actions)
    }

    /// The shared Recents action (`SURFACE-003`); CarPlay only presents the outcome.
    private func playRecent(_ id: UUID, startingAt catalogSongID: String?) async {
        guard runtime?.libraryRestoration.isReady == true, let playbackController, let modelContext,
              let recent = try? RecentCollectionRepository.recent(id: id, in: modelContext) else {
            refreshLibraryLists()
            return
        }
        let started = await MusicKitActivityLog.shared.withOrigin(.carPlay) {
            await playbackController.playRecent(recent, startingAt: catalogSongID, context: modelContext)
        }
        refreshAfterTrackAction()
        if started {
            showNowPlaying()
        } else if playbackController.playbackFailure == nil {
            showPlaybackFailure(title: "Playback failed")
        }
    }

    /// Back from Now Playing while an album or artist plays goes to its list,
    /// then Recents, then the root, however Now Playing was opened.
    private func placePlayingRecentBeneathNowPlaying(_ groupKey: String) {
        guard !isPlacingPlayingPlaylist, runtime?.libraryRestoration.isReady == true,
              let interfaceController, let modelContext,
              interfaceController.topTemplate === CPNowPlayingTemplate.shared,
              let recent = (try? RecentCollectionRepository.recents(in: modelContext))?.first(where: { $0.groupKey == groupKey })
        else { return }
        let templates = interfaceController.templates
        let beneath = templates.count >= 2 ? templates[templates.count - 2] : nil
        let belowThat = templates.count >= 3 ? templates[templates.count - 3] : nil
        let beneathIsVisibleRecent = beneath != nil && beneath === visibleRecentTemplate
        guard CarPlayNowPlayingBackStack.needsPlayingRecent(
            beneathRecentID: beneathIsVisibleRecent ? visibleRecentID : nil,
            recentsListBeneathThat: belowThat != nil && belowThat === recentsTemplate,
            playingRecentID: recent.id
        ) else { return }

        let recentsList = makeRecentsTemplate()
        let recentList = makeRecentTemplate(recent)
        isPlacingPlayingPlaylist = true
        interfaceController.popToRootTemplate(animated: false) { [weak self, weak interfaceController] _, _ in
            Task { @MainActor in
                guard let interfaceController else { self?.isPlacingPlayingPlaylist = false; return }
                interfaceController.pushTemplate(recentsList, animated: false) { _, _ in
                    Task { @MainActor in
                        interfaceController.pushTemplate(recentList, animated: false) { _, _ in
                            Task { @MainActor in
                                interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: false) { _, _ in
                                    Task { @MainActor in self?.isPlacingPlayingPlaylist = false }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func isCurrentPlaylist(_ summary: PlaylistSummaryPresentation) -> Bool {
        playbackController?.isPlaying(summary.playbackContext) == true
    }

    private func isCurrentTrack(_ summary: TrackSummaryPresentation, in playlist: PlaylistRecord) -> Bool {
        guard let playbackController,
              let modelContext,
              let trackID = summary.trackID,
              let track = try? TrackRecordRepository.track(id: trackID, in: modelContext) else {
            return false
        }

        return CurrentPlaylistItemMatcher.isCurrent(
            itemID: summary.id,
            track: track,
            playlist: playlist,
            currentPlaylistID: playbackController.currentPlaylistContext?.musicPlaylistID,
            currentPlaylistItem: playbackController.currentPlaylistItem,
            currentTrack: playbackController.currentTrack
        )
    }

    private func playlistSummaries() throws -> [PlaylistSummaryPresentation] {
        guard let modelContext else { return [] }
        return try CarPlayLibrarySnapshot.playlistSummaries(in: modelContext)
    }

    private func showPlaylist(_ summary: PlaylistSummaryPresentation) async {
        guard runtime?.libraryRestoration.isReady == true, let modelContext else { return }

        do {
            guard try PlaylistRepository.playlist(id: summary.id, in: modelContext) != nil else {
                setRootTemplate(animated: true)
                return
            }
            let template = try makePlaylistTemplate(summary)
            await pushList(template, renderer: playlistRenderer) { [weak self] in self?.visiblePlaylistTemplate === template }
        } catch {
            showError(title: "Playlist failed", message: UserFacingError.message(for: error))
        }
    }

    /// Builds a playlist's list and makes it the visible playlist template.
    private func makePlaylistTemplate(_ summary: PlaylistSummaryPresentation) throws -> CPListTemplate {
        guard let modelContext,
              let storedPlaylist = try PlaylistRepository.playlist(id: summary.id, in: modelContext) else {
            throw PlaylistSyncError.playlistNotFound
        }
        let playlist = try PlaylistRepository.canonicalPlaylist(for: storedPlaylist, in: modelContext)
        visiblePlaylistID = playlist.id
        visiblePlaylistScope = summary.playbackScope
        try PlaylistCollageService.prepareSnapshots(in: modelContext)
        playlistRenderer.stop()
        playlistRenderer = CarPlayListRenderer()
        let template = CPListTemplate(title: summary.title, sections: [])
        try updatePlaylistList(template, playlist: playlist)
        visiblePlaylistTemplate = template
        return template
    }

    /// CarPlay's back arrow on Now Playing pops one template. When CarPlay
    /// opens Now Playing itself (its Now Playing button, or audio already
    /// playing on connect) that template is the root list. Put the playing
    /// playlist underneath instead, so Back always returns to it.
    private func placePlayingPlaylistBeneathNowPlaying() {
        if let groupKey = playbackController?.playingCollectionGroupKey {
            placePlayingRecentBeneathNowPlaying(groupKey)
            return
        }
        guard !isPlacingPlayingPlaylist, runtime?.libraryRestoration.isReady == true,
              let interfaceController, let modelContext,
              interfaceController.topTemplate === CPNowPlayingTemplate.shared,
              let playing = (try? playlistSummaries())?.first(where: isCurrentPlaylist),
              let stored = try? PlaylistRepository.playlist(id: playing.id, in: modelContext),
              let canonical = try? PlaylistRepository.canonicalPlaylist(for: stored, in: modelContext) else { return }
        let templates = interfaceController.templates
        let beneath = templates.count >= 2 ? templates[templates.count - 2] : nil
        let beneathIsVisiblePlaylist = beneath != nil && beneath === visiblePlaylistTemplate
        guard CarPlayNowPlayingBackStack.needsPlayingPlaylist(
            beneathPlaylistID: beneathIsVisiblePlaylist ? visiblePlaylistID : nil,
            beneathScope: beneathIsVisiblePlaylist ? visiblePlaylistScope : nil,
            playingPlaylistID: canonical.id,
            playingScope: playing.playbackScope
        ), let playlistTemplate = try? makePlaylistTemplate(playing) else { return }

        isPlacingPlayingPlaylist = true
        interfaceController.popToRootTemplate(animated: false) { [weak self, weak interfaceController] _, _ in
            Task { @MainActor in
                guard let interfaceController else { self?.isPlacingPlayingPlaylist = false; return }
                interfaceController.pushTemplate(playlistTemplate, animated: false) { _, _ in
                    Task { @MainActor in
                        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: false) { _, _ in
                            Task { @MainActor in self?.isPlacingPlayingPlaylist = false }
                        }
                    }
                }
            }
        }
    }

    private func updatePlaylistList(_ template: CPListTemplate, playlist: PlaylistRecord) throws {
        guard let modelContext else { return }
        let scope = carPlayDisplayScope(for: playlist)
        let tracks: [TrackSummaryPresentation]
        if let activePlaylistSnapshot = playbackController?.activePlaylistSnapshot,
           activePlaylistSnapshot.playlistID == playlist.id,
           activePlaylistSnapshot.musicPlaylistID == playlist.musicPlaylistID,
           activePlaylistSnapshot.playbackScope == scope {
            tracks = CarPlayLibrarySnapshot.trackSummaries(
                from: activePlaylistSnapshot,
                playlistItems: try PlaylistItemRepository.items(
                    forPlaylistID: playlist.id,
                    in: modelContext
                ),
                sourcePlaylists: try PlaylistRepository.allPlaylists(in: modelContext)
            )
        } else {
            tracks = try CarPlayLibrarySnapshot.trackSummaries(
                forPlaylistID: playlist.id,
                scope: scope,
                in: modelContext
            )
        }

        typealias Row = CarPlayListPresentation.Row
        var actions: [String: @MainActor () async -> Void] = [
            "shuffle": { [weak self] in await self?.shuffleAndPlay(playlist, scope: scope) }
        ]
        let rows: [Row] = tracks.prefix(max(0, CPListTemplate.maximumItemCount - 1)).map { summary in
            let id = summary.id.uuidString
            actions[id] = { [weak self] in await self?.play(summary, in: playlist, scope: scope) }
            return Row(id: id, title: summary.title, detail: summary.detailText,
                isPlaying: isCurrentTrack(summary, in: playlist), isEnabled: summary.isPlayable,
                artwork: .track(url: summary.artworkURLString, playlistID: playlist.musicPlaylistID))
        }
        // The playlist's art over its tracks, as on the phone, with a shuffle
        // button in the header.
        let header = CarPlayListPresentation.Header(
            title: template.title ?? playlist.name,
            subtitle: PlaylistSummaryPresentation.trackCountLabel(tracks.count),
            artwork: PlaylistCollageService.snapshot(for: playlist, scope: scope)
                .map { .collage($0, playlistID: playlist.musicPlaylistID, scope: scope) },
            shuffleActionID: "shuffle",
            canShuffle: !rows.isEmpty
        )
        playlistRenderer.update(.init(header: header, sections: [
            .init(id: "tracks", rows: rows.isEmpty
                ? [Row(id: "empty", title: "No playable tracks", detail: "Sync this playlist in Overplay.", isEnabled: false)] : rows)
        ]), on: template, actions: actions)
    }

    private var visiblePlaylistScope: PlaylistPlaybackScope = .active
    private var isPlacingPlayingPlaylist = false

    private func carPlayDisplayScope(for playlist: PlaylistRecord) -> PlaylistPlaybackScope {
        visiblePlaylistID == playlist.id ? visiblePlaylistScope : .active
    }

    private func play(
        _ summary: TrackSummaryPresentation,
        in playlist: PlaylistRecord,
        scope: PlaylistPlaybackScope = .active
    ) async {
        guard runtime?.libraryRestoration.isReady == true, let playbackController, let modelContext else { return }

        do {
            guard let trackID = summary.trackID,
                  let track = try TrackRecordRepository.track(id: trackID, in: modelContext) else {
                refreshLibraryLists()
                return
            }

            let settings = try SettingsRepository.settings(in: modelContext)
            await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                await playbackController.playPlaylist(
                    playlist, startingAt: track, scope: scope, settings: settings, context: modelContext
                )
            }

            refreshAfterTrackAction()
            presentPlaybackOutcome(for: playlist, scope: scope)
        } catch {
            showError(title: "Playback failed", message: UserFacingError.message(for: error))
        }
    }

    /// The controller decides success (`SURFACE-003`): a shared failure shows
    /// its own alert with Try Again; a start that never happened reports why;
    /// anything else, including a non-blocking note, goes to Now Playing.
    private func presentPlaybackOutcome(for playlist: PlaylistRecord, scope: PlaylistPlaybackScope) {
        guard let playbackController else { return }
        switch CarPlayPlaybackOutcome.decide(
            hasPlaybackFailure: playbackController.playbackFailure != nil,
            current: playbackController.currentPlaylistContext,
            requested: playlist.playbackContext(scope)
        ) {
        case .nowPlaying: showNowPlaying()
        case .sharedFailure: break
        case .notStarted: showPlaybackFailure(title: "Playback failed")
        }
    }

    private func shuffleAndPlay(_ playlist: PlaylistRecord, scope: PlaylistPlaybackScope) async {
        guard runtime?.libraryRestoration.isReady == true, let playbackController, let modelContext else { return }
        do {
            let settings = try SettingsRepository.settings(in: modelContext)
            await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                await playbackController.playPlaylist(playlist, scope: scope, settings: settings, context: modelContext)
            }
            refreshAfterTrackAction()
            presentPlaybackOutcome(for: playlist, scope: scope)
        } catch {
            showError(title: "Playback failed", message: UserFacingError.message(for: error))
        }
    }

    private func resumeBeforeRestoration() async {
        guard let playbackController, let modelContext else { return }
        await MusicKitActivityLog.shared.withOrigin(.carPlay) {
            await playbackController.play(context: modelContext)
        }
        if playbackController.playbackFailure == nil { showNowPlaying() }
    }

    private func showNowPlaying() {
        guard let interfaceController else { return }
        let nowPlayingTemplate = CPNowPlayingTemplate.shared

        if interfaceController.topTemplate !== nowPlayingTemplate {
            interfaceController.pushTemplate(nowPlayingTemplate, animated: true, completion: nil)
        }
    }

    private func configureNowPlayingTemplate() {
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        nowPlayingTemplate.add(self)
        nowPlayingTemplate.isUpNextButtonEnabled = true
        nowPlayingTemplate.isAlbumArtistButtonEnabled = false
        updateNowPlayingButtons()
        updateAlbumArtistButton()
    }

    /// Playlist linking, One True Playlist role changes, and sync only touch
    /// SwiftData, which the playback observation cannot see. Without this the
    /// root menu could stay stale until playback changed or CarPlay reconnected
    /// — which is what the manual Refresh button used to paper over.
    private func scheduleLibraryRefresh(reason: String) {
        MusicKitActivityLog.shared.record(.carPlayRefreshRequested, detail: reason)
        guard libraryRefreshTask == nil else { return }
        libraryRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.libraryRefreshTask = nil
            self.refreshLibraryLists()
        }
    }

    private func startLibraryChangeObservation() {
        stopLibraryChangeObservation()
        libraryChangeObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard LibraryPresentationChange(notification: notification).affectsLibrary else { return }
            let containerID = (notification.object as? ModelContext).map { ObjectIdentifier($0.container) }
            MainActor.assumeIsolated {
                guard let self, let container = self.modelContext?.container,
                      containerID == ObjectIdentifier(container) else { return }
                self.updateNowPlayingButtons()
                self.scheduleLibraryRefresh(reason: "persistence")
            }
        }
    }

    private func stopLibraryChangeObservation() {
        if let libraryChangeObserver {
            NotificationCenter.default.removeObserver(libraryChangeObserver)
        }
        libraryChangeObserver = nil
    }

    private func startPlaybackObservation() {
        playbackObservationGeneration += 1
        observePlaybackController(generation: playbackObservationGeneration)
    }

    private func stopPlaybackObservation() {
        playbackObservationGeneration += 1
    }

    private func observePlaybackController(generation: Int) {
        guard generation == playbackObservationGeneration,
              let playbackController else {
            return
        }

        withObservationTracking {
            // Deliberately excludes elapsed/duration: they change every
            // second, the button signature doesn't use them, and tracking
            // them made every tick re-run settings + signature fetches.
            // CarPlay's progress bar reads Now Playing metadata, not this.
            _ = runtime?.libraryRestoration.isReady
            _ = runtime?.libraryRestoration.importRevision
            _ = playbackController.currentPlaylistContext
            _ = playbackController.hasLiveQueue
            _ = playbackController.currentMember?.localTrackID
            _ = playbackController.currentTrack?.id
            _ = playbackController.displayedIsEvicted
            _ = playbackController.activePlaylistSnapshot?.updatedAt
            _ = playbackController.playbackFailure
            _ = playbackController.intent?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackObservationGeneration else { return }
                if let runtime = self.runtime, let context = self.modelContext,
                   runtime.authorizationService.readiness.isReady,
                   runtime.libraryRestoration.hasImported,
                   !runtime.startupViewModel.hasStartedAuthorizedServices {
                    runtime.startupViewModel.retryLibraryPreparation(dependencies:
                        runtime.startupViewModel.dependencies(modelContext: context, runtime: runtime,
                            authorizationService: runtime.authorizationService, playbackController: runtime.playbackController))
                }
                self.updateNowPlayingButtons()
                self.updateAlbumArtistButton()
                self.scheduleLibraryRefresh(reason: "playback")
                self.presentDeliveryStallAlertIfNeeded()
                self.observePlaybackController(generation: generation)
            }
        }
    }

    /// The shared playback failure (`PLAY-014`), once per episode, and again,
    /// replacing the earlier alert, when the player becomes stuck or answers
    /// again (#84). It waits out a grace period, and goes once the failure
    /// clears. "Try Again" runs the same user-initiated recovery as Play on
    /// every other surface; a stuck player is not offered it.
    private func presentDeliveryStallAlertIfNeeded() {
        guard let playbackController else { return }
        failureAlertCheck?.cancel()
        let failure = playbackController.playbackFailure
        if failure == nil { alertedFailureKind = nil }
        guard let interfaceController else { return }
        let presented = interfaceController.presentedTemplate
        switch CarPlayFailureAlert.decide(
            failure: failure,
            alerted: alertedFailureKind,
            isShowingFailureAlert: presented != nil && presented === failureAlert,
            now: .now
        ) {
        case .none:
            return
        case .dismiss:
            interfaceController.dismissTemplate(animated: true, completion: nil)
            return
        case .wait(let due):
            failureAlertCheck = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.presentDeliveryStallAlertIfNeeded()
            }
            return
        case .present:
            break
        }
        guard let failure else { return }
        if let presented {
            // Only the earlier failure alert is replaced; anything else stays.
            guard presented === failureAlert else { return }
            interfaceController.dismissTemplate(animated: false) { [weak self] _, _ in
                Task { @MainActor in self?.presentDeliveryStallAlertIfNeeded() }
            }
            return
        }

        alertedFailureKind = failure.kind
        let retry = CPAlertAction(title: "Try Again", style: .default) { [weak self, weak interfaceController] _ in
            interfaceController?.dismissTemplate(animated: true, completion: nil)
            Task { @MainActor in
                guard let self, let controller = self.playbackController, let context = self.modelContext else { return }
                await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                    await controller.play(context: context)
                }
            }
        }
        let dismiss = CPAlertAction(title: "OK", style: .cancel) { [weak interfaceController] _ in
            interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let template = CPAlertTemplate(
            titleVariants: [failure.message, failure.offersRetry ? "Playback problem" : "Turn mobile data off and on"],
            actions: failure.offersRetry ? [retry, dismiss] : [dismiss]
        )
        failureAlert = template
        interfaceController.presentTemplate(template, animated: true, completion: nil)
    }

    private func updateNowPlayingButtons() {
        guard runtime?.libraryRestoration.isReady == true, let playbackController, let modelContext else { return }
        let signature = CarPlayNowPlayingButtonSignature.make(
            playbackController: playbackController,
            context: modelContext
        )
        // Loss of attribution while the same playlist hydrates is not a new
        // action layout. Keep it in place, but disable curation until resolved.
        let layout = signature.resolvingLayout(
            previous: lastNowPlayingButtonSignature,
            samePlaylist: playbackController.currentPlaylistContext != nil
                && playbackController.currentPlaylistContext == lastNowPlayingContext
        )
        let actions = CarPlayNowPlayingActionPolicy.actions(
            playlistRole: layout.playlistRole, isRetired: layout.isEvicted, canAddToOverplay: layout.canAddToOverplay
        )
        lastNowPlayingButtonSignature = layout
        lastNowPlayingContext = playbackController.currentPlaylistContext
        let needsLayout = actions != displayedActions
        if needsLayout {
            displayedActions = actions
            displayedActionButtons = actions.map { action in
                switch action {
                case .shuffle: shuffleButton
                case .repeatMode: repeatButton
                case .promote: makePromoteButton()
                case .retire: makeEvictButton()
                case .restore: makeRestoreButton()
                case .addToTriage: makeAddButton(systemImage: "tray.and.arrow.down", toOneTruePlaylist: false)
                case .addToOneTruePlaylist: makeAddButton(systemImage: "arrow.up.circle", toOneTruePlaylist: true)
                }
            }
        }
        for (action, button) in zip(displayedActions, displayedActionButtons) {
            let enabled = switch action {
            case .shuffle, .repeatMode: playbackController.hasLiveQueue
            case .addToTriage: signature.hasCurrentTrack && signature.canAddToOverplay
            case .addToOneTruePlaylist: signature.hasCurrentTrack && signature.canAddToOneTruePlaylist
            case .promote, .retire, .restore: signature.hasCurrentTrack && signature.playlistRole != nil
            }
            if button.isEnabled != enabled {
                button.isEnabled = enabled
                MusicKitActivityLog.shared.record(.carPlayNowPlayingButtonState,
                    detail: "action=\(action) enabled=\(enabled)")
            }
        }
        if needsLayout {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons(displayedActionButtons)
            MusicKitActivityLog.shared.record(.carPlayNowPlayingButtonsUpdate,
                detail: "layout actions=\(actions) " + playbackController.playbackModeDiagnosticDescription)
        }
    }

    private func makeEvictButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "archivebox")) { [weak self] _ in
            Task { @MainActor in
                await self?.evictCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func makeRestoreButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "tray")) { [weak self] _ in
            Task { @MainActor in
                self?.restoreCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func makePromoteButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "arrow.up.circle")) { [weak self] _ in
            Task { @MainActor in
                await self?.promoteCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func makeAddButton(systemImage: String, toOneTruePlaylist: Bool) -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: systemImage)) { [weak self] _ in
            Task { @MainActor in
                await self?.addCurrentTrack(toOneTruePlaylist: toOneTruePlaylist)
            }
        }
        button.isEnabled = playbackController?.canAddCurrentToOverplay == true
        return button
    }

    private func buttonImage(systemImage: String) -> UIImage {
        let traitCollection = interfaceController?.carTraitCollection
            ?? UITraitCollection(displayScale: 1)
        return CarPlayNowPlayingButtonImageFactory.image(
            systemName: systemImage,
            traitCollection: traitCollection
        ) ?? UIImage()
    }

    private func evictCurrentTrack() async {
        guard runtime?.libraryRestoration.isReady == true, let playbackController, let modelContext else { return }

        do {
            let settings = try SettingsRepository.settings(in: modelContext)
            await playbackController.evictCurrent(settings: settings, context: modelContext)
            refreshAfterTrackAction()
        } catch {
            showError(title: "Track action failed", message: UserFacingError.message(for: error))
        }
    }

    private func promoteCurrentTrack() async {
        guard runtime?.libraryRestoration.isReady == true, let playbackController, let modelContext else { return }

        do {
            let settings = try SettingsRepository.settings(in: modelContext)
            await playbackController.promoteCurrent(settings: settings, context: modelContext)
            refreshAfterTrackAction()
        } catch {
            showError(title: "Track action failed", message: UserFacingError.message(for: error))
        }
    }

    private func addCurrentTrack(toOneTruePlaylist: Bool) async {
        guard runtime?.libraryRestoration.isReady == true, let playbackController, let modelContext else { return }
        await MusicKitActivityLog.shared.withOrigin(.carPlay) {
            if toOneTruePlaylist {
                await playbackController.addCurrentToOneTruePlaylist(context: modelContext)
            } else {
                await playbackController.addCurrentToTriage(context: modelContext)
            }
        }
        refreshAfterTrackAction()
        if playbackController.canAddCurrentToOverplay {
            showError(title: "Couldn't add", message: playbackController.statusMessage ?? "Apple Music didn't respond.")
        }
    }

    // MARK: - Play Album and Play Artist (`PLAY-018`)

    /// CarPlay's own album/artist button on Now Playing opens them.
    private func updateAlbumArtistButton() {
        let enabled = playbackController?.canPlayCurrentCollection == true
        if CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled != enabled {
            CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = enabled
        }
    }

    /// Two rows above Now Playing: an action list, not a browse level
    /// (the one exception to `CAR-001`).
    private func showCollectionActions() {
        guard let interfaceController, let track = playbackController?.currentTrack else { return }
        let album = CPListItem(text: track.albumTitle.map { "Play album \($0)" } ?? "Play album", detailText: nil,
                               image: CarPlayListSymbolImage.image(systemName: "square.stack", color: .label))
        album.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.playCollection(.album)
                completion()
            }
        }
        let artist = CPListItem(text: track.artistName.isEmpty ? "Play artist" : "Play \(track.artistName)", detailText: nil,
                                image: CarPlayListSymbolImage.image(systemName: "music.mic", color: .label))
        artist.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.playCollection(.artist)
                completion()
            }
        }
        let template = CPListTemplate(title: "Dive Deeper", sections: [CPListSection(items: [album, artist])])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func playCollection(_ request: PlaybackCollection.Request) async {
        guard let playbackController, let modelContext, let interfaceController else { return }
        let started = await MusicKitActivityLog.shared.withOrigin(.carPlay) {
            await playbackController.playCurrentCollection(request, context: modelContext)
        }
        if interfaceController.topTemplate !== CPNowPlayingTemplate.shared {
            interfaceController.popTemplate(animated: true, completion: nil)
        }
        // A shared failure presents its own alert with Try Again.
        if !started, playbackController.playbackFailure == nil {
            showPlaybackFailure(title: "Playback failed")
        }
    }

    private func restoreCurrentTrack() {
        guard runtime?.libraryRestoration.isReady == true, let playbackController, let modelContext else { return }

        _ = playbackController.restoreCurrent(context: modelContext)
        refreshAfterTrackAction()
    }

    private func refreshAfterTrackAction() {
        refreshLibraryLists()
        updateNowPlayingButtons()
    }

    private func refreshLibraryLists() {
        guard let interfaceController,
              let listTemplate = CarPlayListTemplateUpdater.refreshTarget(
                topTemplate: interfaceController.topTemplate,
                templateStack: interfaceController.templates
              ) else {
            return
        }

        if listTemplate === rootListTemplate {
            updateRootList(listTemplate)
            return
        }

        if let rootListTemplate {
            updateRootList(rootListTemplate)
        }

        if listTemplate === recentsTemplate {
            updateRecentsList(listTemplate)
            return
        }
        if listTemplate === libraryCategoryTemplate {
            updateLibraryCategoryList(listTemplate)
            return
        }
        if listTemplate === libraryItemTemplate {
            updateLibraryItemList(listTemplate)
            return
        }
        if listTemplate === visibleRecentTemplate {
            guard let visibleRecentID, let modelContext,
                  let recent = try? RecentCollectionRepository.recent(id: visibleRecentID, in: modelContext) else { return }
            updateRecentList(listTemplate, recent: recent)
            return
        }

        guard listTemplate === visiblePlaylistTemplate,
              let visiblePlaylistID,
              let modelContext,
              let storedPlaylist = try? PlaylistRepository.playlist(id: visiblePlaylistID, in: modelContext),
              let playlist = try? PlaylistRepository.canonicalPlaylist(
                for: storedPlaylist,
                in: modelContext
              ) else {
            return
        }

        self.visiblePlaylistID = playlist.id
        try? updatePlaylistList(listTemplate, playlist: playlist)
    }

    private func refreshVisibleTemplate() {
        refreshLibraryLists()
        rootRenderer.retryMissingArtwork()
        playlistRenderer.retryMissingArtwork()
    }

    private func popToRootMenu() {
        guard let interfaceController else { return }
        interfaceController.popToRootTemplate(animated: true) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshLibraryLists()
                self?.rootRenderer.retryMissingArtwork()
            }
        }
    }

    private func showError(title: String, message: String) {
        guard let interfaceController else { return }
        let action = CPAlertAction(title: "OK", style: .default) { [weak interfaceController] _ in
            interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let template = CPAlertTemplate(titleVariants: ["\(title): \(message)", title], actions: [action])
        interfaceController.presentTemplate(template, animated: true, completion: nil)
    }
}

extension CarPlayCoordinator: CPInterfaceControllerDelegate {
    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        guard aTemplate === CPNowPlayingTemplate.shared else { return }
        placePlayingPlaylistBeneathNowPlaying()
    }
}

extension CarPlayCoordinator: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        popToRootMenu()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        showCollectionActions()
    }
}
