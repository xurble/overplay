import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(PlaybackController.self) private var playbackController

    @Query(filter: #Predicate<PlaylistRecord> { $0.isActive }, sort: \PlaylistRecord.name) private var playlists: [PlaylistRecord]
    @Query private var playlistItems: [PlaylistItemRecord]
    @Query(sort: \RecentCollectionRecord.lastPlayedAt, order: .reverse) private var recentRecords: [RecentCollectionRecord]
    @State private var leadArtworkSide = DashboardLayout.defaultLeadArtworkSide
    /// Fitting bookkeeping. Not observed: updating it must never redraw the
    /// screen, least of all mid-scroll.
    @State private var leadArtworkFit = LeadArtworkFit()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var settings: OverplaySettings

    var body: some View {
        let builder = presentationBuilder
        List {
            Section {
                if let oneTruePlaylist {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: oneTruePlaylist)
                    } label: {
                        oneTruePlaylistArtwork(for: oneTruePlaylist, summary: builder.summary(for: oneTruePlaylist))
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: DashboardLayout.leadArtworkTopInset, leading: 16,
                                              bottom: DashboardLayout.blockSpacing, trailing: 16))
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
                let triageSummary = builder.summary(for: triageBucket)
                let retiredSummary = builder.summary(for: triageBucket, scope: .retired)
                Section {
                    NavigationLink {
                        PlaylistManagementView(settings: settings, playlist: triageBucket)
                    } label: {
                        playlistHomeRow(for: triageBucket, summary: triageSummary,
                                        detail: triageSummary.triageDetail(sourceCount: triageSourceCount))
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
        .background(alignment: .top) {
            DeepDivesPlaceholderView()
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { leadArtworkFit.deepDivesHeight = $0 }
        }
        .onScrollGeometryChange(for: DashboardFit.self) { geometry in
            DashboardFit(
                containerHeight: geometry.containerSize.height,
                contentHeight: geometry.contentSize.height,
                topInset: geometry.contentInsets.top,
                scrolledDistance: geometry.contentOffset.y + geometry.contentInsets.top,
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
    }

    /// Sizes the lead artwork once, as if every element is present: the large
    /// title, Triage, Retired and a full Recent Deep Dives section (measured
    /// from a stand-in when there are none). With all of them, the last row
    /// ends one block spacing above the mini player. The size locks at the
    /// first scroll and never changes; scrolling only moves the page.
    private func fitLeadArtwork(_ fit: DashboardFit) {
        guard !leadArtworkFit.isLocked, oneTruePlaylist != nil else { return }
        guard PlayerPlacement(horizontalSizeClass) == .sheet else {
            leadArtworkSide = DashboardLayout.defaultLeadArtworkSide
            return
        }
        leadArtworkFit.restingTopInset = max(leadArtworkFit.restingTopInset, fit.topInset)
        guard fit.scrolledDistance <= 1 else {
            if leadArtworkFit.isSized { leadArtworkFit.isLocked = true }
            return
        }
        let deepDivesHeight = leadArtworkFit.deepDivesHeight
        guard fit.contentHeight > 0, deepDivesHeight > 0 else { return }
        let artworkRowInsets = DashboardLayout.leadArtworkTopInset + DashboardLayout.blockSpacing
        var otherRowsHeight = fit.contentHeight - leadArtworkSide - artworkRowInsets
        if recentRecords.isEmpty { otherRowsHeight += deepDivesHeight }
        let available = fit.containerHeight - leadArtworkFit.restingTopInset - MiniPlayerLayout.collapsedHeight
            - DashboardLayout.blockSpacing - otherRowsHeight - artworkRowInsets
        let side = min(max(available, DashboardLayout.minimumLeadArtworkSide), fit.width - 32)
        if abs(side - leadArtworkSide) >= 1 { leadArtworkSide = side }
        leadArtworkFit.isSized = true
    }

    /// The One True Playlist leads the screen as artwork alone, sized to fill
    /// the first screen.
    private func oneTruePlaylistArtwork(for playlist: PlaylistRecord, summary: PlaylistSummaryPresentation) -> some View {
        ZStack(alignment: .bottomTrailing) {
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

    private func playlistHomeRow(for playlist: PlaylistRecord, summary: PlaylistSummaryPresentation,
                                 detail: String? = nil) -> some View {
        PlaylistHomeRowView(
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

    private var presentationBuilder: PlaylistPresentationBuilder {
        PlaylistPresentationBuilder(
            playlists: playlists,
            items: playlistItems,
            tracks: [],
            playingContext: playbackController.playingPlaylistContext,
            // Nothing here shows a track's artwork, so skip the track lookups.
            includesArtwork: false
        )
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
    static let leadArtworkTopInset: CGFloat = 8
    static let defaultLeadArtworkSide: CGFloat = 192
    static let minimumLeadArtworkSide: CGFloat = 120
}

private struct DashboardFit: Equatable {
    var containerHeight: CGFloat
    var contentHeight: CGFloat
    var topInset: CGFloat
    var scrolledDistance: CGFloat
    var width: CGFloat
}

/// Invisible copy of the Recent Deep Dives rows (heading, then a tile row)
/// with the same fonts and insets, so the lead artwork reserves their height.
private struct DeepDivesPlaceholderView: View {
    @Environment(\.defaultMinListRowHeight) private var minimumRowHeight

    var body: some View {
        // Each list row is its content plus insets, but never under the
        // list's minimum row height.
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Deep Dives")
                .font(.headline)
                .padding(.top, DashboardLayout.blockSpacing)
                .padding(.bottom, 6)
                .frame(minHeight: minimumRowHeight)
            RecentTilePlaceholderView()
                .padding(.top, 4)
                .frame(minHeight: minimumRowHeight)
        }
        .accessibilityHidden(true)
    }
}

private final class LeadArtworkFit {
    var restingTopInset: CGFloat = 0
    var deepDivesHeight: CGFloat = 0
    var isSized = false
    var isLocked = false
}
