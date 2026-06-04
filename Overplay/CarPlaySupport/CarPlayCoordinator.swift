import CarPlay
import Foundation
import SwiftData
import UIKit

@MainActor
final class CarPlayCoordinator: NSObject {
    private weak var interfaceController: CPInterfaceController?
    private var playbackController: PlaybackController?
    private var remoteCommandService: RemoteCommandService?
    private var modelContext: ModelContext?
    private var refreshTask: Task<Void, Never>?

    func connect(interfaceController: CPInterfaceController, runtime: AppRuntime) {
        self.interfaceController = interfaceController
        playbackController = runtime.playbackController
        remoteCommandService = runtime.remoteCommandService
        modelContext = runtime.makeModelContext()

        if let modelContext {
            runtime.playbackController.startMonitoring(context: modelContext)
            runtime.remoteCommandService.install(playbackController: runtime.playbackController, context: modelContext)
        }

        configureNowPlayingTemplate()
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
        interfaceController = nil
        modelContext = nil
        playbackController = nil
        remoteCommandService = nil
        CPNowPlayingTemplate.shared.remove(self)
    }

    private func setRootTemplate(animated: Bool) {
        guard let interfaceController else { return }
        interfaceController.setRootTemplate(makeRootTemplate(), animated: animated, completion: nil)
    }

    private func makeRootTemplate() -> CPListTemplate {
        let sections = makeSections()
        let template = CPListTemplate(title: "Overplay", sections: sections)
        template.trailingNavigationBarButtons = [
            CPBarButton(title: "Refresh") { [weak self] _ in
                Task { @MainActor in
                    self?.setRootTemplate(animated: true)
                }
            }
        ]
        return template
    }

    private func makeSections() -> [CPListSection] {
        guard modelContext != nil else {
            return [
                CPListSection(items: [disabledItem(title: "Overplay is starting", detail: "Try again in a moment.")])
            ]
        }

        var sections = [CPListSection]()
        sections.append(CPListSection(items: playerItems(), header: "Player", sectionIndexTitle: nil))

        do {
            let summaries = try playlistSummaries()
            let oneTrueItems = summaries
                .filter(\.isOneTruePlaylist)
                .map(playlistItem(for:))
            let linkedItems = summaries
                .filter { !$0.isOneTruePlaylist }
                .map(playlistItem(for:))

            if !oneTrueItems.isEmpty {
                sections.append(CPListSection(items: oneTrueItems, header: "One True Playlist", sectionIndexTitle: nil))
            }

            if !linkedItems.isEmpty {
                sections.append(CPListSection(items: linkedItems, header: "Linked Playlists", sectionIndexTitle: nil))
            }

            if oneTrueItems.isEmpty && linkedItems.isEmpty {
                sections.append(CPListSection(items: [disabledItem(title: "No linked playlists", detail: "Open Overplay on iPhone to choose playlists.")]))
            }
        } catch {
            sections.append(CPListSection(items: [disabledItem(title: "Could not load playlists", detail: error.localizedDescription)]))
        }

        return sections
    }

    private func playerItems() -> [CPListItem] {
        let nowPlayingTitle = playbackController?.currentTrack?.title ?? "Now Playing"
        let nowPlayingDetail = playbackController?.currentTrack.map { "\($0.artistName) - \($0.albumTitle ?? "Overplay")" }
            ?? "Open the CarPlay player"
        let nowPlayingItem = CPListItem(text: nowPlayingTitle, detailText: nowPlayingDetail)
        nowPlayingItem.accessoryType = .disclosureIndicator
        nowPlayingItem.isPlaying = playbackController?.isPlaying == true
        nowPlayingItem.handler = { [weak self] _, completion in
            Task { @MainActor in
                self?.showNowPlaying()
                completion()
            }
        }

        return [nowPlayingItem]
    }

    private func playlistItem(for summary: CarPlayPlaylistSummary) -> CPListItem {
        let item = CPListItem(text: summary.title, detailText: summary.detailText)
        item.accessoryType = .disclosureIndicator
        item.isPlaying = playbackController?.currentPlaylistID == summary.musicPlaylistID
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.play(summary)
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

    private func playlistSummaries() throws -> [CarPlayPlaylistSummary] {
        guard let modelContext else { return [] }
        return try CarPlayLibrarySnapshot.playlistSummaries(in: modelContext)
    }

    private func play(_ summary: CarPlayPlaylistSummary) async {
        guard let playbackController, let modelContext else { return }

        do {
            guard let playlist = try PlaylistRepository.playlist(id: summary.id, in: modelContext) else {
                setRootTemplate(animated: true)
                return
            }

            let settings = try SettingsRepository.settings(in: modelContext)
            await playbackController.playPlaylist(playlist, settings: settings, context: modelContext)
            setRootTemplate(animated: false)
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
        nowPlayingTemplate.updateNowPlayingButtons([
            CPNowPlayingShuffleButton { [weak self] button in
                Task { @MainActor in
                    guard let self, let playbackController = self.playbackController, let modelContext = self.modelContext else { return }
                    await playbackController.toggleShuffle(context: modelContext)
                    button.isSelected = playbackController.shuffleEnabled
                    self.syncPlaybackModes()
                }
            },
            CPNowPlayingRepeatButton { [weak self] _ in
                self?.playbackController?.toggleRepeat()
                self?.syncPlaybackModes()
            }
        ])
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
