import SwiftUI

extension EnvironmentValues {
    /// The share of the column a list header's artwork takes, from the
    /// leading edge; nil for the full width. Where the list sits above the
    /// player (an open phone held in portrait): half, or three quarters
    /// while the sidebar narrows the list (owner request, 2026-10-30).
    @Entry var listHeaderArtworkWidth: CGFloat? = nil
}

/// A list's header: its details with Shuffle and Play beside them, then its
/// artwork, the column's full width or the share
/// `listHeaderArtworkWidth` gives it (owner request, 2026-10-30).
struct ListHeaderView<Details: View, Artwork: View>: View {
    @Environment(\.listHeaderArtworkWidth) private var artworkWidth

    var shuffleTitle: String
    var canShuffle: Bool
    var shuffleIdentifier: String? = nil
    var onShuffle: () async -> Void
    @ViewBuilder var details: () -> Details
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                details()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ShuffleAndPlayButton(title: shuffleTitle, action: onShuffle)
                    .disabled(!canShuffle)
                    .accessibilityIdentifier(shuffleIdentifier ?? "")
            }
            if let artworkWidth {
                artwork()
                    .containerRelativeFrame(.horizontal) { length, _ in (length * artworkWidth).rounded(.down) }
            } else {
                artwork()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

#Preview {
    ListHeaderView(shuffleTitle: "Shuffle and Play", canShuffle: true) {
    } details: {
        Text("Album · 12 songs").font(.subheadline).foregroundStyle(.secondary)
    } artwork: {
        RoundedRectangle(cornerRadius: 16).fill(.purple).aspectRatio(1, contentMode: .fit)
    }
    .padding()
}
