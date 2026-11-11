import SwiftUI

/// Shown in place of the app when the library store cannot be opened
/// (`STORE-001`). It offers no action: the store is left exactly as it is.
struct LibraryStoreUnavailableView: View {
    var detail: String

    var body: some View {
        ContentUnavailableView {
            Label("Can't Open Your Library", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Overplay couldn't open its library, so nothing is playing or syncing. Your library hasn't been changed. Try quitting and reopening Overplay, or installing the latest version.")
        } actions: {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    LibraryStoreUnavailableView(detail: "SwiftDataError: loadIssueModelContainer")
}
