import SwiftUI

/// A list's Shuffle and Play: a round, filled button with the shuffle
/// symbol, beside the list's title. Filled, because purple on glass is
/// illegible on a dark background.
struct ShuffleAndPlayButton: View {
    var title: String
    var action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: "shuffle")
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .help(title)
    }
}

#Preview {
    ShuffleAndPlayButton(title: "Shuffle and Play") {}
        .padding()
}
