import CarPlay
import Foundation
import Observation
import SwiftData
import UIKit

@MainActor
final class CarPlayCoordinator: NSObject {
    private weak var interfaceController: CPInterfaceController?
    private var playbackController: PlaybackController?
    private var remoteCommandService: RemoteCommandService?
    private var modelContext: ModelContext?
    private var refreshTask: Task<Void, Never>?
    private var playbackObservationGeneration = 0
    private var lastNowPlayingButtonSignature: CarPlayNowPlayingButtonSignature?
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
        startPlaybackObservation()
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
        refreshTask = nil
        stopPlaybackObservation()
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
        item.isPlaying = isCurrentPlaylist(summary)
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
        item.isPlaying = isCurrentTrack(summary, in: playlist)
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.play(summary, in: playlist)
                completion()
            }
        }
        return item
    }

    private func isCurrentPlaylist(_ summary: PlaylistSummaryPresentation) -> Bool {
        guard let playbackController,
              let musicPlaylistID = summary.musicPlaylistID,
              playbackController.currentTrack != nil else {
            return false
        }

        return playbackController.currentPlaylistID == musicPlaylistID
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
            currentPlaylistID: playbackController.currentPlaylistID,
            currentPlaylistItem: playbackController.currentPlaylistItem,
            currentTrack: playbackController.currentTrack
        )
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
        let tracks = try CarPlayLibrarySnapshot.trackSummaries(
            forPlaylistID: playlist.id,
            playbackModeState: playbackController?.playbackModeState(for: playlist.musicPlaylistID),
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
                refreshLibraryLists()
                return
            }

            let settings = try SettingsRepository.settings(in: modelContext)
            await playbackController.playPlaylist(playlist, startingAt: track, settings: settings, context: modelContext)
            refreshLibraryLists()
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
            _ = playbackController.currentPlaylistID
            _ = playbackController.currentTrack?.id
            _ = playbackController.displayedSkipCount
            _ = playbackController.displayedIsProtected
            _ = playbackController.displayedIsEvicted
            _ = playbackController.shuffleEnabled
            _ = playbackController.repeatEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackObservationGeneration else { return }
                self.updateNowPlayingButtons(force: false)
                self.refreshLibraryLists()
                self.observePlaybackController(generation: generation)
            }
        }
    }

    private func updateNowPlayingButtons(force: Bool) {
        guard let playbackController, let settings = currentSettings() else { return }
        let signature = CarPlayNowPlayingButtonSignature.make(
            playbackController: playbackController,
            settings: settings
        )
        guard force || signature != lastNowPlayingButtonSignature else { return }

        lastNowPlayingButtonSignature = signature
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            makeShuffleButton(),
            makeRepeatButton(),
            makeTrackHealthButton()
        ])
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
        let health = trackHealthPresentation() ?? TrackHealthPresentation(
            status: .healthy,
            isEvicted: false,
            isProtected: false
        )
        let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        return (UIImage(systemName: health.systemImage, withConfiguration: configuration) ?? UIImage())
            .withRenderingMode(.alwaysTemplate)
    }

    private func currentSettings() -> OverplaySettings? {
        guard let modelContext else { return nil }
        return try? SettingsRepository.settings(in: modelContext)
    }

    private func nowPlayingPresentation() -> NowPlayingPresentation? {
        guard let playbackController, let settings = currentSettings() else { return nil }
        return NowPlayingPresentationFactory.presentation(
            playbackController: playbackController,
            settings: settings
        )
    }

    private func trackHealthPresentation() -> TrackHealthPresentation? {
        guard let playbackController, let settings = currentSettings() else { return nil }
        return NowPlayingPresentationFactory.trackHealthPresentation(
            playbackController: playbackController,
            settings: settings
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
        guard let nowPlaying = nowPlayingPresentation(), nowPlaying.trackID != nil else {
            return "No track is currently playing."
        }

        let health = trackHealthPresentation() ?? TrackHealthPresentation(
            status: .healthy,
            isEvicted: false,
            isProtected: false
        )
        return "\(nowPlaying.title): \(health.title)."
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
        refreshLibraryLists()
        updateNowPlayingButtons(force: true)
    }

    private func refreshLibraryLists() {
        guard let interfaceController,
              let listTemplate = interfaceController.topTemplate as? CPListTemplate else {
            return
        }

        if listTemplate.title == "Overplay" {
            visiblePlaylistID = nil
            listTemplate.updateSections(makeRootSections())
            return
        }

        guard let visiblePlaylistID,
              let modelContext,
              let playlist = try? PlaylistRepository.playlist(id: visiblePlaylistID, in: modelContext),
              listTemplate.title == playlist.name,
              let sections = try? playlistSections(for: playlist) else {
            return
        }

        listTemplate.updateSections(sections)
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
