import SwiftData
import SwiftUI

/// Every Recent Deep Dive as a grid of artwork (`PLAY-019`): the sidebar's
/// way to the albums and artists the dashboard shows as one row.
struct DeepDivesView: View {
    @Query(sort: \RecentCollectionRecord.lastPlayedAt, order: .reverse) private var recentRecords: [RecentCollectionRecord]
    @State private var filterText = ""
    @State private var isFiltering = false

    var body: some View {
        let recents = RecentCollectionRepository.distinct(recentRecords)
        let shownRecents = recents.filter(matchesFilter)
        ScrollView {
            if shownRecents.isEmpty, !recents.isEmpty {
                ListFilterNoMatchesView()
                    .padding()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: RecentTileView.side), spacing: 18)], alignment: .leading, spacing: 22) {
                ForEach(shownRecents) { recent in
                    NavigationLink {
                        RecentCollectionView(recent: recent)
                            .nowPlayingColumnToggle()
                    } label: {
                        RecentTileView(recent: recent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .overlay {
            if recents.isEmpty {
                ContentUnavailableView("No Deep Dives Yet", systemImage: "square.stack",
                    description: Text("Albums and artists you play from Now Playing appear here."))
            }
        }
        .listFilter(text: $filterText, isPresented: $isFiltering, prompt: "Albums or artists")
        .miniPlayerScrollContentInset()
        .navigationTitle("Deep Dives")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// An album matches its title or artist, as Library's Albums do; an
    /// artist matches its name.
    private func matchesFilter(_ recent: RecentCollectionRecord) -> Bool {
        guard !filterText.isEmpty else { return true }
        return recent.collection.kind == .album
            ? ListFilter.matches(filterText, recent.title, recent.songs.first?.artistName)
            : ListFilter.matches(filterText, recent.title)
    }
}

#Preview {
    NavigationStack {
        DeepDivesView()
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
