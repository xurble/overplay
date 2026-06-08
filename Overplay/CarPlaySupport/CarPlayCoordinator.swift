import CarPlay
import Foundation
import SwiftData
import UIKit

@MainActor
final class CarPlayCoordinator: NSObject {
    private struct NowPlayingButtonSignature: Equatable {
        var trackID: String?
        var skipCount: Int
        var isProtected: Bool
        var isEvicted: Bool
        var shuffleEnabled: Bool
        var repeatEnabled: Bool
    }

    private weak var interfaceController: CPInterfaceController?
    private var playbackController: PlaybackController?
    private var remoteCommandService: RemoteCommandService?
    private var modelContext: ModelContext?
    private var refreshTask: Task<Void, Never>?
    private var nowPlayingRefreshTask: Task<Void, Never>?
    private var lastNowPlayingButtonSignature: NowPlayingButtonSignature?
    private var visiblePlaylistID: UUID?

    func connect(interfaceController: CPInterfaceController, runtime: AppRuntime) {
        self.interfaceController = interfaceController
        playbackController = runtime.playbackController
        remoteCommandService = runtime.remoteCommandService
        modelContext = runtime.makeModelContext()

        if let modelContext {
            runtime.playbackController.startMonitoring(context: modelContext)
            runtime.remoteCommandService.update(playbackController: runtime.playbackController, context: modelContext)
        }

        configureNowPlayingTemplate()
        startNowPlayingRefresh()
        setRootTemplate(animated: false)

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await runtime.authorizationService.refresh()
            guard !Task.isCancelled else { return }
            self?.setRootTemplate(animated: false)
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        nowPlayingRefreshTask?.cancel()
        refreshTask = nil
        nowPlayingRefreshTask = nil
        interfaceController = nil
        modelContext = nil
        playbackController = nil
        remoteCommandService = nil
        visiblePlaylistID = nil
        lastNowPlayingButtonSignature = nil
        CPNowPlayingTemplate.shared.remove(self)
    }

    private func setRootTemplate(animated: Bool) {
        guard let interfaceController else { return }
        visiblePlaylistID = nil
        interfaceController.setRootTemplate(makeRootTemplate(), animated: animated, completion: nil)
    }

    private func makeRootTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Overplay", sections: makeRootSections())
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Refresh") { [weak self] _ in
                Task { @MainActor in
                    self?.setRootTemplate(animated: true)
                }
            }
        ]
        return template
    }

    private func makeRootSections() -> [CPListSection] {
        guard modelContext != nil else {
            return [
                CPListSection(items: [disabledItem(title: "Overplay is starting", detail: "Try again in a moment.")])
            ]
        }

        do {
            let summaries = try playlistSummaries()
            let mainItems = summaries
                .filter { $0.role == .oneTruePlaylist }
                .map(playlistItem(for:))
            let triageItems = summaries
                .filter { $0.role != .oneTruePlaylist }
                .map(playlistItem(for:))

            var sections = [CPListSection]()
            if !mainItems.isEmpty {
                sections.append(CPListSection(items: mainItems, header: "Main Playlist", sectionIndexTitle: nil))
            }
            if !triageItems.isEmpty {
                sections.append(CPListSection(items: triageItems, header: "Triage Playlists", sectionIndexTitle: nil))
            }

            if sections.isEmpty {
                sections.append(CPListSection(items: [
                    disabledItem(title: "No linked playlists", detail: "Open Overplay on iPhone to choose playlists.")
                ]))
            }
            return sections
        } catch {
            return [
                CPListSection(items: [disabledItem(title: "Could not load playlists", detail: error.localizedDescription)])
            ]
        }
    }

    private func playlistItem(for summary: PlaylistSummaryPresentation) -> CPListItem {
        let item = CPListItem(text: summary.title, detailText: summary.playableTrackCountLabel)
        item.accessoryType = .disclosureIndicator
        item.isPlaying = playbackController?.currentPlaylistID == summary.musicPlaylistID
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.showPlaylist(summary)
                completion()
            }
        }
        return item
    }

    private func trackItem(_ summary: TrackSummaryPresentation, playlist: PlaylistRecord) -> CPListItem {
        let item = CPListItem(text: summary.title, detailText: summary.detailText)
        item.isPlaying = playbackController?.currentPlaylistItem?.id == summary.id
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.play(summary, in: playlist)
                completion()
            }
        }
        return item
    }

    private func disabledItem(title: String, detail: String) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        item.isEnabled = false
        return item
    }

    private func playlistSummaries() throws -> [PlaylistSummaryPresentation] {
        guard let modelContext else { return [] }
        return try CarPlayLibrarySnapshot.playlistSummaries(in: modelContext)
    }

    private func showPlaylist(_ summary: PlaylistSummaryPresentation) {
        guard let interfaceController, let modelContext else { return }

        do {
            guard let playlist = try PlaylistRepository.playlist(id: summary.id, in: modelContext) else {
                setRootTemplate(animated: true)
                return
            }

            visiblePlaylistID = playlist.id
            let template = CPListTemplate(
                title: playlist.name,
                sections: try playlistSections(for: playlist)
            )
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        } catch {
            showError(title: "Playlist failed", message: error.localizedDescription)
        }
    }

    private func playlistSections(for playlist: PlaylistRecord) throws -> [CPListSection] {
        guard let modelContext else { return [] }
        let settings = try SettingsRepository.settings(in: modelContext)
        let tracks = try CarPlayLibrarySnapshot.trackSummaries(
            forPlaylistID: playlist.id,
            evictAfterSkips: settings.evictAfterSkips,
            in: modelContext
        )

        guard !tracks.isEmpty else {
            return [
                CPListSection(items: [
                    disabledItem(title: "No playable tracks", detail: "Sync this playlist in Overplay.")
                ])
            ]
        }

        return [
            CPListSection(items: tracks.map { trackItem($0, playlist: playlist) })
        ]
    }

    private func play(_ summary: TrackSummaryPresentation, in playlist: PlaylistRecord) async {
        guard let playbackController, let modelContext else { return }

        do {
            guard let trackID = summary.trackID,
                  let track = try TrackRecordRepository.track(id: trackID, in: modelContext) else {
                refreshVisiblePlaylistRows()
                return
            }

            let settings = try SettingsRepository.settings(in: modelContext)
            await playbackController.playPlaylist(playlist, startingAt: track, settings: settings, context: modelContext)
            refreshVisiblePlaylistRows()
            updateNowPlayingButtons(force: true)
            showNowPlaying()
        } catch {
            showError(title: "Playback failed", message: error.localizedDescription)
        }
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
        nowPlayingTemplate.isUpNextButtonEnabled = false
        nowPlayingTemplate.isAlbumArtistButtonEnabled = false
        updateNowPlayingButtons(force: true)
    }

    private func startNowPlayingRefresh() {
        nowPlayingRefreshTask?.cancel()
        nowPlayingRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.updateNowPlayingButtons(force: false)
            }
        }
    }

    private func updateNowPlayingButtons(force: Bool) {
        let signature = nowPlayingButtonSignature()
        guard force || signature != lastNowPlayingButtonSignature else { return }

        lastNowPlayingButtonSignature = signature
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            makeShuffleButton(),
            makeRepeatButton(),
            makeTrackHealthButton()
        ])
    }

    private func nowPlayingButtonSignature() -> NowPlayingButtonSignature {
        NowPlayingButtonSignature(
            trackID: playbackController?.currentTrack?.id,
            skipCount: playbackController?.displayedSkipCount ?? 0,
            isProtected: playbackController?.displayedIsProtected == true,
            isEvicted: playbackController?.displayedIsEvicted == true,
            shuffleEnabled: playbackController?.shuffleEnabled == true,
            repeatEnabled: playbackController?.repeatEnabled == true
        )
    }

    private func makeShuffleButton() -> CPNowPlayingShuffleButton {
        let button = CPNowPlayingShuffleButton { [weak self] button in
            Task { @MainActor in
                guard let self, let playbackController = self.playbackController, let modelContext = self.modelContext else { return }
                await playbackController.toggleShuffle(context: modelContext)
                button.isSelected = playbackController.shuffleEnabled
                self.syncPlaybackModes()
                self.updateNowPlayingButtons(force: true)
            }
        }
        button.isSelected = playbackController?.shuffleEnabled == true
        return button
    }

    private func makeRepeatButton() -> CPNowPlayingRepeatButton {
        let button = CPNowPlayingRepeatButton { [weak self] button in
            guard let self else { return }
            self.playbackController?.toggleRepeat()
            button.isSelected = self.playbackController?.repeatEnabled == true
            self.syncPlaybackModes()
            self.updateNowPlayingButtons(force: true)
        }
        button.isSelected = playbackController?.repeatEnabled == true
        return button
    }

    private func makeTrackHealthButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: healthButtonImage()) { [weak self] _ in
            Task { @MainActor in
                self?.showTrackHealthMenu()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func healthButtonImage() -> UIImage {
        let symbolName = switch currentHealthStatus() {
        case .healthy:
            "checkmark.circle.fill"
        case .caution:
            "exclamationmark.circle.fill"
        case .critical:
            "exclamationmark.triangle.fill"
        }

        let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        return (UIImage(systemName: symbolName, withConfiguration: configuration) ?? UIImage())
            .withRenderingMode(.alwaysTemplate)
    }

    private func currentHealthStatus() -> TrackHealthStatus {
        guard let playbackController else { return .healthy }
        let evictAfterSkips: Int
        if let modelContext, let settings = try? SettingsRepository.settings(in: modelContext) {
            evictAfterSkips = settings.evictAfterSkips
        } else {
            evictAfterSkips = 3
        }

        return TrackHealthStatus.resolve(
            skipCount: playbackController.displayedSkipCount,
            evictAfterSkips: evictAfterSkips,
            isEvicted: playbackController.displayedIsEvicted,
            isProtected: playbackController.displayedIsProtected
        )
    }

    private func showTrackHealthMenu() {
        guard let interfaceController, playbackController?.currentTrack != nil else { return }

        let resetAction = CPAlertAction(title: "Reset Skip Count", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.resetCurrentSkipCount()
                self?.dismissPresentedTemplate()
            }
        }
        let keepSafeAction = CPAlertAction(title: "Keep Safe", style: .default) { [weak self] _ in
            Task { @MainActor in
                self?.protectCurrentTrack()
                self?.dismissPresentedTemplate()
            }
        }
        let evictAction = CPAlertAction(title: "Evict Now", style: .destructive) { [weak self] _ in
            Task { @MainActor in
                await self?.evictCurrentTrack()
                self?.dismissPresentedTemplate()
            }
        }
        let cancelAction = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            Task { @MainActor in
                self?.dismissPresentedTemplate()
            }
        }

        let template = CPActionSheetTemplate(
            title: "Track Health",
            message: trackHealthMessage(),
            actions: [resetAction, keepSafeAction, evictAction, cancelAction]
        )
        interfaceController.presentTemplate(template, animated: true, completion: nil)
    }

    private func trackHealthMessage() -> String {
        guard let track = playbackController?.currentTrack else {
            return "No track is currently playing."
        }

        return switch currentHealthStatus() {
        case .healthy:
            "\(track.title) is healthy."
        case .caution:
            "\(track.title) has accumulated skips."
        case .critical:
            "\(track.title) is one skip away from eviction."
        }
    }

    private func resetCurrentSkipCount() {
        do {
            let context = try currentCarPlayTrackContext()
            try TrackHealthActionService.resetSkipCount(
                context.item,
                playlist: context.playlist,
                message: "Skip count reset in CarPlay",
                in: context.modelContext
            )
            refreshAfterHealthAction()
        } catch {
            showError(title: "Health action failed", message: error.localizedDescription)
        }
    }

    private func protectCurrentTrack() {
        do {
            let context = try currentCarPlayTrackContext()
            try TrackHealthActionService.protectTrack(
                context.item,
                playlist: context.playlist,
                message: "Protected in CarPlay",
                in: context.modelContext
            )
            refreshAfterHealthAction()
        } catch {
            showError(title: "Health action failed", message: error.localizedDescription)
        }
    }

    private func evictCurrentTrack() async {
        guard let playbackController, let modelContext else { return }

        do {
            let settings = try SettingsRepository.settings(in: modelContext)
            await playbackController.evictCurrent(settings: settings, context: modelContext)
            refreshAfterHealthAction()
        } catch {
            showError(title: "Health action failed", message: error.localizedDescription)
        }
    }

    private func currentCarPlayTrackContext() throws -> (
        modelContext: ModelContext,
        playlist: PlaylistRecord,
        item: PlaylistItemRecord
    ) {
        guard let modelContext, let playbackController, let musicItemID = playbackController.currentTrack?.id else {
            throw CarPlayHealthActionError.noCurrentTrack
        }
        guard let musicPlaylistID = playbackController.currentPlaylistID,
              let playlist = try PlaylistRepository.playlist(musicPlaylistID: musicPlaylistID, in: modelContext) else {
            throw CarPlayHealthActionError.noCurrentPlaylist
        }
        guard let item = try PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: musicItemID,
            currentPlaylistItem: playbackController.currentPlaylistItem,
            playlist: playlist,
            in: modelContext
        ) else {
            throw CarPlayHealthActionError.noCurrentTrack
        }

        playbackController.currentPlaylistItem = item
        return (modelContext, playlist, item)
    }

    private func refreshAfterHealthAction() {
        refreshVisiblePlaylistRows()
        updateNowPlayingButtons(force: true)
    }

    private func refreshVisiblePlaylistRows() {
        guard let interfaceController,
              let visiblePlaylistID,
              let modelContext,
              let playlistTemplate = interfaceController.topTemplate as? CPListTemplate,
              let playlist = try? PlaylistRepository.playlist(id: visiblePlaylistID, in: modelContext),
              let sections = try? playlistSections(for: playlist) else {
            return
        }

        playlistTemplate.updateSections(sections)
    }

    private func dismissPresentedTemplate() {
        interfaceController?.dismissTemplate(animated: true, completion: nil)
    }

    private func syncPlaybackModes() {
        guard let playbackController else { return }
        remoteCommandService?.syncPlaybackModes(from: playbackController)
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

extension CarPlayCoordinator: CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        setRootTemplate(animated: true)
    }
}

private enum CarPlayHealthActionError: LocalizedError {
    case noCurrentTrack
    case noCurrentPlaylist

    var errorDescription: String? {
        switch self {
        case .noCurrentTrack:
            "Choose a linked playlist track first."
        case .noCurrentPlaylist:
            "The current playback queue is not linked to a playlist."
        }
    }
}
