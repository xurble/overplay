import SwiftUI

struct TrackRowText: View {
    let candidates: [String]
    var lineLimit = 1

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(candidates, id: \.self) { candidate in
                Text(candidate)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
            }
            Text(candidates.last ?? "")
                .lineLimit(lineLimit)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(candidates.first ?? "")
    }
}

#Preview {
    TrackRowText(candidates: TrackTextVariants.candidates(for: "A long song title (Live) [Remastered]"))
        .font(.headline)
        .frame(width: 220)
        .padding()
}
