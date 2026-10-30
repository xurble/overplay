import SwiftUI
import UIKit

/// A swipe button's label with an outline symbol. Given a symbol name, a
/// swipe draws the filled variant whatever the view asks for; a finished
/// image keeps the outline.
struct SwipeLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)) {
                Image(uiImage: image.withRenderingMode(.alwaysTemplate))
            } else {
                Image(systemName: systemImage)
            }
        }
    }
}

#Preview {
    List {
        Text("Swipe me")
            .swipeActions {
                Button { } label: { SwipeLabel(title: "Inbox", systemImage: "tray.and.arrow.down") }
                    .tint(.green)
            }
    }
}
