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
final class CarPlayCoordinator: NSObject {
    private weak var interfaceController: CPInterfaceController?
    private var playbackController: PlaybackController?
    private var remoteCommandService: RemoteCommandService?
    private weak var runtime: AppRuntime?
    private var modelContext: ModelContext?
    private var refreshTask: Task<Void, Never>?
    private var playbackObservationGeneration = 0
    private var lastNowPlayingButtonSignature: CarPlayNowPlayingButtonSignature?
    private var visiblePlaylistID: UUID?
    // Held by identity rather than title: two playlists can share a name, and
    // a playlist can be called "Overplay".
    private weak var rootListTemplate: CPListTemplate?
    private weak var visiblePlaylistTemplate: CPListTemplate?
    private var didPresentDeliveryStallAlert = false
    private var libraryChangeObserver: NSObjectProtocol?

    func connect(interfaceController: CPInterfaceController, runtime: AppRuntime) {
        self.interfaceController = interfaceController
        self.runtime = runtime
        playbackController = runtime.playbackController
        remoteCommandService = runtime.remoteCommandService
        modelContext = runtime.makeModelContext()

        if let modelContext {
            runtime.playbackController.startMonitoring(context: modelContext)
            runtime.remoteCommandService.activate(playbackController: runtime.playbackController, context: modelContext)
        }

        configureNowPlayingTemplate()
        startPlaybackObservation()
        startLibraryChangeObservation()
        setRootTemplate(animated: false)

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await runtime.authorizationService.refresh()
            guard !Task.isCancelled else { return }
            self?.refreshVisibleTemplate()
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        stopPlaybackObservation()
        stopLibraryChangeObservation()

        // Lock Screen handlers keep running after CarPlay disconnects —
        // re-point them at the main context instead of leaving them on the
        // orphaned CarPlay-created one.
        if let runtime, let mainContext = runtime.mainModelContext {
            runtime.remoteCommandService.update(
                playbackController: runtime.playbackController,
                context: mainContext
            )
        }

        interfaceController = nil
        runtime = nil
        modelContext = nil
        playbackController = nil
        remoteCommandService = nil
        visiblePlaylistID = nil
        rootListTemplate = nil
        visiblePlaylistTemplate = nil
        lastNowPlayingButtonSignature = nil
        CPNowPlayingTemplate.shared.remove(self)
    }

    private func setRootTemplate(animated: Bool) {
        guard let interfaceController else { return }
        visiblePlaylistID = nil
        visiblePlaylistTemplate = nil
        let template = CPListTemplate(title: "Overplay", sections: makeRootSections())
        rootListTemplate = template
        interfaceController.setRootTemplate(template, animated: animated, completion: nil)
    }

    private func makeRootSections() -> [CPListSection] {
        guard modelContext != nil else {
            return [
                CPListSection(items: [disabledItem(title: "Overplay is starting", detail: "Try again in a moment.")])
            ]
        }

        do {
            let summaries = try playlistSummaries()
            guard !summaries.isEmpty else {
                return [CPListSection(items: [
                    disabledItem(title: "No linked playlists", detail: "Open Overplay on iPhone to choose playlists.")
                ])]
            }

            // Playlists, then tracks, then Now Playing. Nothing else: a
            // driver should not have to read a menu.
            var sections: [CPListSection] = []
            if let oneTruePlaylist = summaries.first(where: { $0.role == .oneTruePlaylist }) {
                sections.append(CPListSection(items: [playlistItem(for: oneTruePlaylist)]))
            }

            let triageItems = summaries
                .filter { $0.role != .oneTruePlaylist }
                .map(playlistItem(for:))
            if !triageItems.isEmpty {
                sections.append(CPListSection(items: triageItems, header: "Triage Playlists", sectionIndexTitle: nil))
            }
            return sections
        } catch {
            return [
                CPListSection(items: [disabledItem(title: "Could not load playlists", detail: error.localizedDescription)])
            ]
        }
    }

    /// Shuffle and resume report failure through the controller rather than by
    /// throwing, so surface it instead of navigating to a stale player.
    private func showPlaybackFailure(title: String) {
        showError(
            title: title,
            message: playbackController?.statusMessage ?? "Apple Music playback could not start."
        )
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

    private func trackItem(
        _ summary: TrackSummaryPresentation,
        playlist: PlaylistRecord,
        scope: PlaylistPlaybackScope = .active
    ) -> CPListItem {
        let item = CPListItem(text: summary.title, detailText: summary.detailText)
        item.isPlaying = isCurrentTrack(summary, in: playlist)
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.play(summary, in: playlist, scope: scope)
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
            visiblePlaylistTemplate = template
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        } catch {
            showError(title: "Playlist failed", message: error.localizedDescription)
        }
    }

    private func playlistSections(for playlist: PlaylistRecord) throws -> [CPListSection] {
        guard let modelContext else { return [] }
        let scope = carPlayDisplayScope(for: playlist)
        let tracks: [TrackSummaryPresentation]
        if let activePlaylistSnapshot = playbackController?.activePlaylistSnapshot,
           activePlaylistSnapshot.playlistID == playlist.id,
           activePlaylistSnapshot.musicPlaylistID == playlist.musicPlaylistID,
           activePlaylistSnapshot.playbackScope == scope {
            tracks = CarPlayLibrarySnapshot.trackSummaries(from: activePlaylistSnapshot)
        } else {
            tracks = try CarPlayLibrarySnapshot.trackSummaries(
                forPlaylistID: playlist.id,
                playbackOrderState: playbackController?.playbackOrderState(for: playlist.musicPlaylistID, scope: scope),
                scope: scope,
                in: modelContext
            )
        }

        guard !tracks.isEmpty else {
            return [CPListSection(items: [
                disabledItem(title: "No playable tracks", detail: "Sync this playlist in Overplay.")
            ])]
        }

        return [CPListSection(items: tracks.map { trackItem($0, playlist: playlist, scope: scope) })]
    }

    private func carPlayDisplayScope(for playlist: PlaylistRecord) -> PlaylistPlaybackScope {
        guard let playbackController,
              playbackController.currentPlaylistID == playlist.musicPlaylistID else {
            return .active
        }

        return playbackController.currentPlaylistScope
    }

    private func play(
        _ summary: TrackSummaryPresentation,
        in playlist: PlaylistRecord,
        scope: PlaylistPlaybackScope = .active
    ) async {
        guard let playbackController, let modelContext else { return }

        do {
            guard let trackID = summary.trackID,
                  let track = try TrackRecordRepository.track(id: trackID, in: modelContext) else {
                refreshLibraryLists()
                return
            }

            let settings = try SettingsRepository.settings(in: modelContext)
            let intent = CarPlayNavigationPolicy.trackIntent(
                isCurrentTrack: isCurrentTrack(summary, in: playlist),
                isInLiveQueue: playbackController.currentQueueContains(playlist: playlist, scope: scope)
            )

            switch intent {
            case .showPlayer:
                if !playbackController.isPlaying {
                    await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                        await playbackController.play(context: modelContext)
                    }
                }
            case .skipInLiveQueue:
                let didSkip = await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                    await playbackController.playTrackInCurrentQueue(
                        localTrackID: trackID.uuidString,
                        settings: settings,
                        context: modelContext
                    )
                }
                if !didSkip {
                    await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                        await playbackController.playPlaylist(
                            playlist, startingAt: track, scope: scope, settings: settings, context: modelContext
                        )
                    }
                }
            case .startPlaylist:
                await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                        await playbackController.playPlaylist(playlist, startingAt: track, scope: scope, settings: settings, context: modelContext)
                    }
            }

            refreshAfterTrackAction()
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
        nowPlayingTemplate.isUpNextButtonEnabled = true
        nowPlayingTemplate.isAlbumArtistButtonEnabled = false
        updateNowPlayingButtons(force: true)
    }

    /// Playlist linking, One True Playlist role changes, and sync only touch
    /// SwiftData, which the playback observation cannot see. Without this the
    /// root menu could stay stale until playback changed or CarPlay reconnected
    /// — which is what the manual Refresh button used to paper over.
    private func startLibraryChangeObservation() {
        stopLibraryChangeObservation()
        libraryChangeObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLibraryLists()
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
            _ = playbackController.currentPlaylistID
            _ = playbackController.currentTrack?.id
            _ = playbackController.displayedSkipCount
            _ = playbackController.displayedIsEvicted
            _ = playbackController.activePlaylistSnapshot?.updatedAt
            _ = playbackController.isDeliveryStalled
            _ = playbackController.shuffleEnabled
            _ = playbackController.repeatMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackObservationGeneration else { return }
                _ = self.updateNowPlayingButtons(force: false)
                self.refreshLibraryLists()
                self.presentDeliveryStallAlertIfNeeded()
                self.observePlaybackController(generation: generation)
            }
        }
    }

    /// Delivery failures used to be invisible from CarPlay — statusMessage
    /// renders only on iPhone/iPad. Present one dismissible alert per stall
    /// episode; the flag resets when playback recovers.
    private func presentDeliveryStallAlertIfNeeded() {
        guard let playbackController else { return }
        guard playbackController.isDeliveryStalled else {
            didPresentDeliveryStallAlert = false
            return
        }
        guard !didPresentDeliveryStallAlert,
              let interfaceController,
              interfaceController.presentedTemplate == nil else {
            return
        }

        didPresentDeliveryStallAlert = true
        let action = CPAlertAction(title: "OK", style: .default) { [weak interfaceController] _ in
            interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let template = CPAlertTemplate(
            titleVariants: [
                "Playback stalled — check the network connection. Overplay will retry automatically.",
                "Playback stalled"
            ],
            actions: [action]
        )
        interfaceController.presentTemplate(template, animated: true, completion: nil)
    }

    @discardableResult
    private func updateNowPlayingButtons(force: Bool) -> Bool {
        guard let playbackController, let modelContext, let settings = currentSettings() else { return false }
        syncPlaybackModes()
        let signature = CarPlayNowPlayingButtonSignature.make(
            playbackController: playbackController,
            settings: settings,
            context: modelContext
        )
        guard force || signature != lastNowPlayingButtonSignature else { return false }

        lastNowPlayingButtonSignature = signature
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(nowPlayingActionButtons(for: signature))
        return true
    }

    private func nowPlayingActionButtons(for signature: CarPlayNowPlayingButtonSignature) -> [CPNowPlayingButton] {
        CarPlayNowPlayingActionPolicy.actions(
            playlistRole: signature.playlistRole,
            isRetired: signature.isEvicted
        ).map { action in
            switch action {
            case .shuffle: makeShuffleButton()
            case .repeatMode: makeRepeatButton()
            case .promote: makePromoteButton()
            case .retire: makeEvictButton()
            case .restore: makeRestoreButton()
            }
        }
    }

    /// CarPlay's own shuffle control, so it looks and behaves like every other
    /// audio app in the car. `isSelected` reflects MusicKit's mode rather than
    /// anything Overplay keeps.
    private func makeShuffleButton() -> CPNowPlayingShuffleButton {
        let button = CPNowPlayingShuffleButton { [weak self] _ in
            Task { @MainActor in
                guard let self, let modelContext = self.modelContext else { return }
                await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                    await self.playbackController?.toggleShuffle(context: modelContext)
                }
                _ = self.updateNowPlayingButtons(force: true)
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        button.isSelected = playbackController?.shuffleEnabled ?? false
        return button
    }

    private func makeRepeatButton() -> CPNowPlayingRepeatButton {
        let button = CPNowPlayingRepeatButton { [weak self] _ in
            Task { @MainActor in
                guard let self, let modelContext = self.modelContext else { return }
                await MusicKitActivityLog.shared.withOrigin(.carPlay) {
                    await self.playbackController?.toggleRepeatAll(context: modelContext)
                }
                _ = self.updateNowPlayingButtons(force: true)
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        button.isSelected = playbackController?.repeatAllEnabled ?? false
        return button
    }

    private func makeEvictButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "trash")) { [weak self] _ in
            Task { @MainActor in
                await self?.evictCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func makeRestoreButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "arrow.uturn.backward.circle")) { [weak self] _ in
            Task { @MainActor in
                self?.restoreCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func makePromoteButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "star")) { [weak self] _ in
            Task { @MainActor in
                await self?.promoteCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func buttonImage(systemImage: String) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .light)
        return (UIImage(systemName: systemImage, withConfiguration: configuration) ?? UIImage())
            .withRenderingMode(.alwaysTemplate)
    }

    private func currentSettings() -> OverplaySettings? {
        guard let modelContext else { return nil }
        return try? SettingsRepository.settings(in: modelContext)
    }

    private func evictCurrentTrack() async {
        guard let playbackController, let modelContext else { return }

        do {
            let settings = try SettingsRepository.settings(in: modelContext)
            await playbackController.evictCurrent(settings: settings, context: modelContext)
            refreshAfterTrackAction()
        } catch {
            showError(title: "Track action failed", message: error.localizedDescription)
        }
    }

    private func promoteCurrentTrack() async {
        guard let playbackController, let modelContext else { return }

        do {
            let settings = try SettingsRepository.settings(in: modelContext)
            await playbackController.promoteCurrent(settings: settings, context: modelContext)
            refreshAfterTrackAction()
        } catch {
            showError(title: "Track action failed", message: error.localizedDescription)
        }
    }

    private func restoreCurrentTrack() {
        guard let playbackController, let modelContext else { return }

        _ = playbackController.restoreCurrent(context: modelContext)
        refreshAfterTrackAction()
    }

    private func refreshAfterTrackAction() {
        refreshLibraryLists()
        updateNowPlayingButtons(force: true)
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
            CarPlayListTemplateUpdater.update(listTemplate, sections: makeRootSections())
            return
        }

        guard listTemplate === visiblePlaylistTemplate,
              let visiblePlaylistID,
              let modelContext,
              let playlist = try? PlaylistRepository.playlist(id: visiblePlaylistID, in: modelContext),
              let sections = try? playlistSections(for: playlist) else {
            return
        }

        CarPlayListTemplateUpdater.update(listTemplate, sections: sections)
    }

    private func refreshVisibleTemplate() {
        refreshLibraryLists()
    }

    private func popToRootMenu() {
        guard let interfaceController else { return }
        interfaceController.popToRootTemplate(animated: true) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshLibraryLists()
            }
        }
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
        popToRootMenu()
    }
}
