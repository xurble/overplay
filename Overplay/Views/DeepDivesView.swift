import SwiftData
import SwiftUI

/// Every Recent Deep Dive as a grid of artwork (`PLAY-019`): the sidebar's
/// way to the albums and artists the dashboard shows as one row.
struct DeepDivesView: View {
    @Query(sort: \RecentCollectionRecord.lastPlayedAt, order: .reverse) private var recentRecords: [RecentCollectionRecord]

    var body: some View {
        let recents = RecentCollectionRepository.distinct(recentRecords)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: RecentTileView.side), spacing: 18)], alignment: .leading, spacing: 22) {
                ForEach(recents) { recent in
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
        .miniPlayerScrollContentInset()
        .navigationTitle("Deep Dives")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        DeepDivesView()
    }
    .environment(PlaybackController())
    .modelContainer(PreviewContainer.make())
}
