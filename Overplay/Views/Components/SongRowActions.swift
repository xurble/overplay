import SwiftUI

/// A song row's actions: swipes on iPhone and iPad, and on a Mac the same
/// buttons in a right-click menu instead (owner request, 2026-10-31).
struct SongRowActions<Leading: View, Trailing: View>: ViewModifier {
    /// False where the row already has a menu of its own on a Mac.
    var showsMenu: Bool
    var leading: Leading
    var trailing: Trailing

    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.isMacCatalystApp {
            if showsMenu {
                content.contextMenu {
                    leading
                    trailing
                }
            } else {
                content
            }
        } else {
            content
                .swipeActions(edge: .leading) { leading }
                .swipeActions(edge: .trailing) { trailing }
        }
    }
}

extension View {
    func songRowActions<Leading: View, Trailing: View>(
        showsMenu: Bool = true,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(SongRowActions(showsMenu: showsMenu, leading: leading(), trailing: trailing()))
    }
}

#Preview {
    List {
        Text("Swipe me, or right-click on a Mac")
            .songRowActions {
                Button { } label: { SwipeLabel(title: "Overplay", systemImage: "arrow.up.circle") }
                    .tint(.pink)
            } trailing: {
                Button { } label: { SwipeLabel(title: "Inbox", systemImage: "tray.and.arrow.down") }
                    .tint(.green)
            }
    }
}
