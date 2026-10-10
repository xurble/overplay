import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackController.self) private var playbackController

    @Query(filter: #Predicate<PlaylistRecord> { $0.isActive }, sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \RecentCollectionRecord.lastPlayedAt, order: .reverse) private var recentRecords: [RecentCollectionRecord]
    @State private var tracks: [TrackRecord] = []
    @State private var leadArtworkSide = DashboardLayout.defaultLeadArtworkSide
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var settings: OverplaySettings

    var body: some View {
        List {
            Section {
                if let oneTruePlaylist {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: oneTruePlaylist)
                    } label: {
                        oneTruePlaylistArtwork(for: oneTruePlaylist)
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: DashboardLayout.blockSpacing, trailing: 16))
                } else {
                    NavigationLink {
                        PlaylistSelectionView()
                    } label: {
                        PlaylistHomeRowView(
                            title: "Link One True Playlist",
                            detail: "Choose the main playlist Overplay manages.",
                            systemImage: "arrow.up.circle",
                            badgeTint: .pink
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }
            }

            if let triageBucket {
                let retiredSummary = presentationBuilder.summary(for: triageBucket, scope: .retired)
                Section {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: triageBucket)
                    } label: {
                        playlistHomeRow(for: triageBucket, detail: triageDetail(for: triageBucket))
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: triageBucket, scope: .retired)
                    } label: {
                        Label {
                            Text("Retired")
                        } icon: {
                            Image(systemName: retiredSummary.iconIntent.systemImage)
                                .foregroundStyle(retiredSummary.isCurrentPlaybackPlaylist ? .green : .gray)
                        }
                    }
                }
            }

            let recents = RecentCollectionRepository.distinct(recentRecords)
            if !recents.isEmpty {
                Section {
                    Text("Recent Deep Dives")
                        .font(.headline)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: DashboardLayout.blockSpacing, leading: 16, bottom: 6, trailing: 16))
                    RecentsRowView(recents: recents)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
                }
            }
        }
        .listStyle(.plain)
        .onScrollGeometryChange(for: DashboardFit.self) { geometry in
            DashboardFit(
                spareHeight: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentSize.height,
                width: geometry.containerSize.width
            )
        } action: { _, fit in
            fitLeadArtwork(fit)
        }
        .miniPlayerScrollContentInset()
        .navigationTitle("Overplay")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView(settings: settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .task(id: dashboardDataKey) {
            reloadDashboardData()
        }
    }

    /// Sizes the lead artwork so that, scrolled to the top, the last row ends
    /// one block spacing above the mini player.
    private func fitLeadArtwork(_ fit: DashboardFit) {
        guard PlayerPlacement(horizontalSizeClass) == .sheet else {
            leadArtworkSide = DashboardLayout.defaultLeadArtworkSide
            return
        }
        let excess = fit.spareHeight - MiniPlayerLayout.collapsedHeight - DashboardLayout.blockSpacing
        let side = min(max(leadArtworkSide + excess, DashboardLayout.minimumLeadArtworkSide), fit.width - 32)
        if abs(side - leadArtworkSide) >= 1 { leadArtworkSide = side }
    }

    /// The One True Playlist leads the screen as artwork alone, sized to fill
    /// the first screen.
    private func oneTruePlaylistArtwork(for playlist: PlaylistRecord) -> some View {
        let summary = presentation(for: playlist)
        return ZStack(alignment: .bottomTrailing) {
            PlaylistCollageThumbnailView(playlist: playlist)
                .frame(width: leadArtworkSide, height: leadArtworkSide)

            Image(systemName: summary.iconIntent.systemImage)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(badgeTint(for: summary, role: playlist.role), in: Circle())
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(playlist.name)
        .accessibilityAddTraits(.isButton)
    }

    private func playlistHomeRow(for playlist: PlaylistRecord, detail: String? = nil) -> some View {
        let summary = presentation(for: playlist)
        return PlaylistHomeRowView(
            title: playlist.name,
            detail: detail ?? summary.dashboardDetailText,
            playlist: playlist,
            systemImage: summary.iconIntent.systemImage,
            badgeTint: badgeTint(for: summary, role: playlist.role)
        )
    }

    private func badgeTint(for summary: PlaylistSummaryPresentation, role: PlaylistRole) -> Color {
        if summary.isCurrentPlaybackPlaylist {
            return .green
        }

        return role == .oneTruePlaylist ? .pink : .teal

    }

    private var dashboardDataKey: String {
        playlists.map(\.id.uuidString).joined(separator: "-")
            + playlistItems.map(\.trackID.uuidString).joined(separator: "-")
    }

    private var oneTruePlaylist: PlaylistRecord? {
        if let playlistID = settings.selectedPlaylistID,
           let playlist = playlists.first(where: { $0.musicPlaylistID == playlistID && $0.role == .oneTruePlaylist && $0.isActive }) {
            return playlist
        }

        return playlists.first { $0.role == .oneTruePlaylist && $0.isActive }
    }

    private var triageBucket: PlaylistRecord? {
        return playlists.first { $0.isTriageBucket }
    }

    private var triageSourceCount: Int {
        playlists.filter { $0.role == .triageSource && $0.isActive }.count
    }

    private func triageDetail(for bucket: PlaylistRecord) -> String {
        let trackCount = presentation(for: bucket).activeTrackCount
        let tracks = trackCount == 1 ? "1 track" : "\(trackCount) tracks"
        let sources = triageSourceCount == 1 ? "1 playlist" : "\(triageSourceCount) playlists"
        return "\(tracks) from \(sources)"
    }

    private func presentation(for playlist: PlaylistRecord) -> PlaylistSummaryPresentation {
        presentationBuilder.summary(for: playlist)
    }

    private var presentationBuilder: PlaylistPresentationBuilder {
        PlaylistPresentationBuilder(
            playlists: playlists,
            items: playlistItems,
            tracks: tracks,
            playingContext: playbackController.playingPlaylistContext
        )
    }

    private func reloadDashboardData() {
        tracks = (try? TrackRecordRepository.tracks(ids: playlistItems.map(\.trackID), in: modelContext)) ?? []
    }

}

#Preview {
    NavigationStack {
        DashboardView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}

private enum DashboardLayout {
    /// The gap under the lead artwork, above Recent Deep Dives, and between
    /// the last row and the mini player.
    static let blockSpacing: CGFloat = 14
    static let defaultLeadArtworkSide: CGFloat = 192
    static let minimumLeadArtworkSide: CGFloat = 120
}

private struct DashboardFit: Equatable {
    var spareHeight: CGFloat
    var width: CGFloat
}
