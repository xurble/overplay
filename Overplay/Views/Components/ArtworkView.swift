import SwiftUI

struct ArtworkView: View {
    var urlString: String?
    var cornerRadius: CGFloat = 22

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                            .redacted(reason: .placeholder)
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo, .teal, .pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
        }
    }
}

#Preview {
    ArtworkView()
        .frame(width: 220, height: 220)
        .padding()
}
