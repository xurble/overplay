import SwiftData
import SwiftUI

/// Apple Music search: Overplay's own field at the top, clear of the mini
/// player, and the songs below. On iPhone the field is the whole top bar, with
/// X to leave search; on iPad and the Mac it has no X. Tapping a song plays
/// it. Swiping a song right sends it to the One True Playlist and left to the
/// Inbox, as in a collection's song list; More, beside the Inbox, plays it on
/// its own or adds it to another Apple Music playlist.
struct SearchMusicView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(PlaybackController.self) private var playbackController

    @State private var viewModel = SearchMusicViewModel()
    @State private var songs: [String: RecentCollectionPresentation.Song] = [:]
    @State private var moreResult: SearchSongResult?
    @State private var playlistResult: SearchSongResult?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let results = viewModel.searchService.results
        searchField(resultsList)
            .focusedSceneValue(\.isEditingText, isSearchFocused)
            .onChange(of: viewModel.searchText) { _, newValue in
                Task { await viewModel.clearSearchIfNeeded(newValue) }
            }
            .task(id: "\(results.map(\.id))-\(playbackController.playbackItemMetadataVersion)") {
                let presented = RecentCollectionPresentation.songs(results.map(Self.song), rowID: Self.rowID, in: modelContext)
                songs = Dictionary(presented.map { ($0.catalogID, $0) }, uniquingKeysWith: { first, _ in first })
            }
            .onAppear {
                if results.isEmpty { isSearchFocused = true }
            }
            .confirmationDialog(moreResult?.title ?? "", isPresented: isShowingMore, titleVisibility: .visible,
                                presenting: moreResult) { result in
                moreActions(for: result)
            }
            .sheet(item: $playlistResult) { result in
                NavigationStack {
                    AddToPlaylistView(result: result) { playlistID, name in
                        await viewModel.add(result, toLibraryPlaylistID: playlistID, named: name)
                    }
                }
            }
    }

    /// One bar of its own at the top, so search never moves between layers
    /// and never needs dismissing twice (the system search field did both).
    /// iPhone: it replaces the navigation bar, with X to leave search. iPad
    /// and Mac: search is a sidebar destination, so there is nothing to leave.
    @ViewBuilder
    private func searchField(_ content: some View) -> some View {
        if PlayerPlacement(horizontalSizeClass, verticalSizeClass) == .sheet {
            content
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaBar(edge: .top) {
                    SearchBarView(text: $viewModel.searchText, isFocused: $isSearchFocused, submit: submitSearch) {
                        dismiss()
                    }
                }
        } else {
            content
                .safeAreaBar(edge: .top) {
                    SearchBarView(text: $viewModel.searchText, isFocused: $isSearchFocused, submit: submitSearch, close: nil)
                }
        }
    }

    private func submitSearch() {
        Task { await viewModel.searchService.search(viewModel.searchText) }
    }

    private var resultsList: some View {
        let results = viewModel.searchService.results
        return List {
            if viewModel.searchService.isSearching {
                ProgressView("Searching Apple Music")
            }

            if let message = viewModel.searchService.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }

            ForEach(results) { result in
                if let song = songs[result.id] {
                    // A tap plays the song, as Play Now does.
                    Button {
                        Task { await play(result) }
                    } label: {
                        PlaylistTrackRowView(
                            summary: song.summary,
                            playlistID: Self.collection(for: result).reservedPlaylistID,
                            isCurrent: RecentCollectionPresentation.isCurrent(
                                song, groupKey: Self.collection(for: result).groupKey, controller: playbackController
                            )
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays this song")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                    .swipeActions(edge: .leading) {
                        if song.canMoveToOneTruePlaylist {
                            Button {
                                Task { await move(result, toOneTruePlaylist: true) }
                            } label: {
                                Label("Overplay", systemImage: "arrow.up.circle")
                            }
                            .accessibilityLabel("Add to One True Playlist")
                            .tint(.pink)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if song.canMoveToTriage {
                            Button {
                                Task { await move(result, toOneTruePlaylist: false) }
                            } label: {
                                Label("Inbox", systemImage: "tray.fill")
                            }
                            .accessibilityLabel("Add to the Inbox")
                            .tint(.green)
                        }
                        Button {
                            moreResult = result
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .tint(.gray)
                    }
                    .contextMenu {
                        if song.canMoveToOneTruePlaylist {
                            Button("Add to Overplay", systemImage: "arrow.up.circle") {
                                Task { await move(result, toOneTruePlaylist: true) }
                            }
                        }
                        if song.canMoveToTriage {
                            Button("Add to the Inbox", systemImage: "tray.fill") {
                                Task { await move(result, toOneTruePlaylist: false) }
                            }
                        }
                        moreActions(for: result)
                    }
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerScrollContentInset()
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func moreActions(for result: SearchSongResult) -> some View {
        Button("Play Now", systemImage: "play.fill") {
            Task { await play(result) }
        }
        Button("Add to Playlist…", systemImage: "text.badge.plus") {
            playlistResult = result
        }
    }

    private var isShowingMore: Binding<Bool> {
        Binding { moreResult != nil } set: { if !$0 { moreResult = nil } }
    }

    /// The shared song action, as in a collection's song list: an untracked
    /// song is added, a Triage song promoted, a retired one restored.
    private func move(_ result: SearchSongResult, toOneTruePlaylist: Bool) async {
        await playbackController.moveCollectionSong(Self.song(result), toOneTruePlaylist: toOneTruePlaylist,
                                                    context: modelContext)
    }

    /// Just this song, outside any playlist; not added to Recents.
    private func play(_ result: SearchSongResult) async {
        await playbackController.playCollection(Self.collection(for: result), songs: [Self.song(result)],
                                                startingAt: result.id, recordsRecent: false, context: modelContext)
    }

    private static func collection(for result: SearchSongResult) -> PlaybackCollection {
        PlaybackCollection(kind: .searchSong, catalogID: result.id, title: result.title)
    }

    private static func song(_ result: SearchSongResult) -> PlaybackCollectionSong {
        PlaybackCollectionSong(catalogID: result.id, title: result.title, artistName: result.artistName,
                               albumTitle: result.albumTitle, artworkURLTemplate: result.artworkURL)
    }

    private static let rowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

/// The iPhone search bar: a full-width glass field and, beside it, X to
/// leave search.
private struct SearchBarView: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var submit: () -> Void
    /// Nil where search is a place of its own (a sidebar destination).
    var close: (() -> Void)?

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Songs in Apple Music", text: $text)
                        .focused(isFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular.interactive(), in: Capsule())

                if let close {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Close Search")
                    .accessibilityIdentifier("search-close")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// The user's Apple Music playlists to add a song to. The One True Playlist
/// is left out: swiping right adds to it, with Overplay's tracking.
struct AddToPlaylistView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<PlaylistRecord> { $0.isActive }) private var records: [PlaylistRecord]

    var result: SearchSongResult
    var add: (_ playlistID: String, _ name: String) async -> Void

    private let cache = LibraryCache.shared

    var body: some View {
        let oneTruePlaylistIDs = Set(records.filter { $0.role == .oneTruePlaylist }.map(\.musicPlaylistID))
        let playlists = (cache.items[.playlists] ?? []).filter { !oneTruePlaylistIDs.contains($0.libraryID) }
        List {
            if playlists.isEmpty {
                Text(cache.hasContent(.playlists) ? "No other playlists in your library." : "Loading…")
                    .foregroundStyle(.secondary)
            }
            ForEach(playlists) { playlist in
                Button {
                    Task {
                        dismiss()
                        await add(playlist.libraryID, playlist.title)
                    }
                } label: {
                    LibraryItemRowView(item: playlist)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
            }
        }
        .listStyle(.plain)
        .navigationTitle("Add \(result.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .task { await cache.prepare(.playlists) }
    }
}

#Preview {
    NavigationStack {
        SearchMusicView()
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
