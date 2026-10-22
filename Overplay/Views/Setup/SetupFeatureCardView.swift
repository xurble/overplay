import SwiftUI

struct SetupFeature {
    var symbol: String
    var tint: Color
    var title: String
    var text: String
}

/// One feature of the first-run walkthrough: a symbol, a title and a line.
struct SetupFeatureCardView: View {
    let feature: SetupFeature
    var footnote: String? = nil

    var body: some View {
        SetupCardView {
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                Image(systemName: feature.symbol)
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(feature.tint)
                    .symbolRenderingMode(.hierarchical)
                Text(feature.title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text(feature.text)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let footnote {
                    Text(footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

/// The glass card every setup page sits on.
struct SetupCardView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }
}

#Preview {
    SetupFeatureCardView(
        feature: SetupFeature(symbol: "tray.fill", tint: .teal, title: "Triage",
            text: "New music lands here from playlists you choose."),
        footnote: "Already use Overplay on another device?"
    )
    .padding()
}
