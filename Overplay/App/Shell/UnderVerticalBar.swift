import SwiftUI

extension EnvironmentValues {
    @Entry var playerVerticalBarEdge: HorizontalEdge? = nil
}

/// Lays a view out across a vertical bar (iPhone Duo), whose controls sit at
/// the top: the mini player spans the width below them, and the full-screen
/// player centres on the screen. Other horizontal insets, such as a
/// landscape iPhone's camera side, still apply.
struct UnderVerticalBar: ViewModifier {
    var adjustsSafeArea = true

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content
#else
        if #available(iOS 27.1, *) {
            VerticalBarAware(content: content, adjustsSafeArea: adjustsSafeArea)
        } else {
            content
        }
#endif
    }

#if !targetEnvironment(macCatalyst)
    @available(iOS 27.1, *)
    private struct VerticalBarAware: View {
        @Environment(\.toolbarVerticalEdge) private var verticalBarEdge
        var content: Content
        var adjustsSafeArea: Bool

        var body: some View {
            let adapted = content.environment(\.playerVerticalBarEdge, verticalBarEdge)
            if !adjustsSafeArea {
                adapted
            } else {
                switch verticalBarEdge {
                case .leading: adapted.ignoresSafeArea(.container, edges: .leading)
                case .trailing: adapted.ignoresSafeArea(.container, edges: .trailing)
                default: adapted
                }
            }
        }
    }
#endif
}

/// Reports whether the toolbar is a vertical bar (iPhone Duo), whose items
/// run top to bottom from the leading ones.
struct VerticalBarReader: ViewModifier {
    @Binding var hasVerticalBar: Bool

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content
#else
        if #available(iOS 27.1, *) {
            content.background { Reader(hasVerticalBar: $hasVerticalBar) }
        } else {
            content
        }
#endif
    }

#if !targetEnvironment(macCatalyst)
    @available(iOS 27.1, *)
    private struct Reader: View {
        @Environment(\.toolbarVerticalEdge) private var verticalBarEdge
        @Binding var hasVerticalBar: Bool

        var body: some View {
            Color.clear
                .onChange(of: verticalBarEdge != nil, initial: true) { _, hasBar in
                    hasVerticalBar = hasBar
                }
        }
    }
#endif
}
