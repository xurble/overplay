import SwiftUI

/// Lays a view out across a vertical bar (iPhone Duo), whose controls sit at
/// the top: the mini player spans the width below them, and the full-screen
/// player centres on the screen. Other horizontal insets, such as a
/// landscape iPhone's camera side, still apply.
struct UnderVerticalBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            VerticalBarAware(content: content)
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private struct VerticalBarAware: View {
        @Environment(\.toolbarVerticalEdge) private var verticalBarEdge
        var content: Content

        var body: some View {
            switch verticalBarEdge {
            case .leading: content.ignoresSafeArea(.container, edges: .leading)
            case .trailing: content.ignoresSafeArea(.container, edges: .trailing)
            default: content
            }
        }
    }
}
