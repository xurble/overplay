import SwiftUI

/// Transient messages and errors, from any screen or the shared player, shown
/// as one glass toast instead of in whichever list row happens to be on
/// screen. It rises from the bottom on iPhone and iPad (above the mini
/// player) and drops from the title bar on a Mac; it leaves after a few
/// seconds, or when tapped.
@MainActor
@Observable
final class StatusToast {
    static let shared = StatusToast()

    static let duration: Duration = .seconds(4)

    private(set) var message: String?
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    private init() {}

    func show(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        withAnimation(.spring(duration: 0.35)) { message = text }
        AccessibilityNotification.Announcement(text).post()
        dismissal?.cancel()
        dismissal = Task {
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        withAnimation(.spring(duration: 0.35)) { message = nil }
    }
}

/// Hosts the toast over a window's content.
struct StatusToastOverlay: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private let toast = StatusToast.shared
    private let fromTop = ProcessInfo.processInfo.isMacCatalystApp

    func body(content: Content) -> some View {
        content.overlay(alignment: fromTop ? .top : .bottom) {
            if let message = toast.message {
                StatusToastView(message: message)
                    .padding(.horizontal, 16)
                    // Below a Mac's title bar; above a phone's mini player.
                    .padding(fromTop ? .top : .bottom, fromTop ? 56 : (horizontalSizeClass == .compact ? 96 : 24))
                    .transition(.move(edge: fromTop ? .top : .bottom).combined(with: .opacity))
                    .onTapGesture { toast.dismiss() }
                    .id(message)
            }
        }
    }
}

struct StatusToastView: View {
    var message: String

    var body: some View {
        Text(message)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular, in: .capsule)
            .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    StatusToastView(message: "Couldn't play the album: Apple Music returned no songs to play.")
        .padding()
}
