import CarPlay
import Foundation
import MediaPlayer
import Observation
import OSLog
import SwiftData
import UIKit

@MainActor
final class CarPlayCoordinator: NSObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "CarPlay"
    )

    private weak var interfaceController: CPInterfaceController?
    private var playbackController: PlaybackController?
    private var remoteCommandService: RemoteCommandService?
    private weak var runtime: AppRuntime?
    private var modelContext: ModelContext?
    private var refreshTask: Task<Void, Never>?
    private var playbackObservationGeneration = 0
    private var lastNowPlayingButtonSignature: CarPlayNowPlayingButtonSignature?
    private var visiblePlaylistID: UUID?
    private var didPresentDeliveryStallAlert = false

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
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        } catch {
            showError(title: "Playlist failed", message: error.localizedDescription)
        }
    }

    private func playlistSections(for playlist: PlaylistRecord) throws -> [CPListSection] {
        guard let modelContext else { return [] }
        let scope = carPlayDisplayScope(for: playlist)
        let tracks = try CarPlayLibrarySnapshot.trackSummaries(
            forPlaylistID: playlist.id,
            playbackOrderState: playbackController?.playbackOrderState(for: playlist.musicPlaylistID, scope: scope),
            scope: scope,
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
            CPListSection(items: tracks.map { trackItem($0, playlist: playlist, scope: scope) })
        ]
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
            await playbackController.playPlaylist(playlist, startingAt: track, scope: scope, settings: settings, context: modelContext)
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
            // Deliberately excludes elapsed/duration: they change every
            // second, the button signature doesn't use them, and tracking
            // them made every tick re-run settings + signature fetches.
            // CarPlay's progress bar reads Now Playing metadata, not this.
            _ = playbackController.currentPlaylistID
            _ = playbackController.currentTrack?.id
            _ = playbackController.displayedSkipCount
            _ = playbackController.displayedIsProtected
            _ = playbackController.displayedIsEvicted
            _ = playbackController.isDeliveryStalled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.playbackObservationGeneration else { return }
                if self.updateNowPlayingButtons(force: false) {
                    self.refreshLibraryLists()
                }
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
        if signature.isEvicted {
            return [makeRestoreButton()]
        }

        if signature.playlistRole == .triage {
            return [
                makePromoteButton(),
                makeEvictButton()
            ]
        }

        return [makeEvictButton()]
    }

    private func makeShuffleButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "shuffle")) { [weak self] button in
            Task { @MainActor in
                self?.logModeButtonTap(kind: "shuffle", button: button)
                await self?.applyCarPlayShuffleToggle()
            }
        }
        button.isEnabled = playbackController?.currentPlaylistID != nil
        logModeButtonCreation(kind: "shuffle", button: button)
        return button
    }

    private func applyCarPlayShuffleToggle() async {
        guard let playbackController else { return }

        Self.logger.debug(
            "CarPlay shuffle push applying: commandCenterBefore=\(self.remotePlaybackModeDescription(), privacy: .public)"
        )
        if let remoteCommandService {
            let status = await remoteCommandService.applyShuffleModeCommand(
                .items,
                source: "CarPlay"
            )
            Self.logger.debug(
                "CarPlay shuffle push remote status=\(String(describing: status), privacy: .public), commandCenterAfter=\(self.remotePlaybackModeDescription(), privacy: .public)"
            )
            guard status == .success else {
                syncPlaybackModes()
                updateNowPlayingButtons(force: true)
                return
            }
        } else if let modelContext {
            await playbackController.reshuffleCurrentPlaylist(context: modelContext)
            syncPlaybackModes()
            Self.logger.debug(
                "CarPlay shuffle push fallback applied, commandCenterAfter=\(self.remotePlaybackModeDescription(), privacy: .public)"
            )
        }

        updateNowPlayingButtons(force: true)
    }

    private func logModeButtonCreation(kind: String, button: CPNowPlayingButton) {
        Self.logger.debug(
            "CarPlay \(kind, privacy: .public) button created: enabled=\(button.isEnabled, privacy: .public) selected=\(button.isSelected, privacy: .public), model=\(self.playbackModeDescription(), privacy: .public), commandCenter=\(self.remotePlaybackModeDescription(), privacy: .public)"
        )
    }

    private func logModeButtonTap(kind: String, button: CPNowPlayingButton) {
        Self.logger.debug(
            "CarPlay \(kind, privacy: .public) button tapped: enabled=\(button.isEnabled, privacy: .public) selected=\(button.isSelected, privacy: .public), model=\(self.playbackModeDescription(), privacy: .public), commandCenter=\(self.remotePlaybackModeDescription(), privacy: .public)"
        )
    }

    private func playbackModeDescription() -> String {
        guard let playbackController else {
            return "unavailable"
        }

        return "playlist=\(playbackController.currentPlaylistID ?? "nil")"
    }

    private func remotePlaybackModeDescription() -> String {
        let commandCenter = MPRemoteCommandCenter.shared()
        return "shuffle=\(String(describing: commandCenter.changeShuffleModeCommand.currentShuffleType)), repeat=\(String(describing: commandCenter.changeRepeatModeCommand.currentRepeatType))"
    }

    private func makeEvictButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "trash.fill")) { [weak self] _ in
            Task { @MainActor in
                await self?.evictCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func makeRestoreButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "arrow.uturn.backward.circle.fill")) { [weak self] _ in
            Task { @MainActor in
                self?.restoreCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func makePromoteButton() -> CPNowPlayingImageButton {
        let button = CPNowPlayingImageButton(image: buttonImage(systemImage: "star.fill")) { [weak self] _ in
            Task { @MainActor in
                await self?.promoteCurrentTrack()
            }
        }
        button.isEnabled = playbackController?.currentTrack != nil
        return button
    }

    private func buttonImage(systemImage: String) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
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

    private func refreshVisibleTemplate() {
        guard interfaceController?.topTemplate is CPListTemplate else {
            return
        }

        refreshLibraryLists()
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
