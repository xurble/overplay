import SwiftUI

/// Narrows what a list shows, never what it plays: a row tapped while
/// filtered plays as it would in the whole list.
enum ListFilter {
    /// A list's header, hidden while filtering: closing the filter scrolls
    /// back to it.
    static let headerID = "list-filter-header"

    /// Any field contains the query, ignoring case and accents. An empty
    /// query matches everything.
    static func matches(_ query: String, _ fields: String?...) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return fields.contains { $0?.localizedStandardContains(query) == true }
    }

    /// What a list of songs matches: an album's songs match only their
    /// titles, and an artist's songs, sharing the artist, their albums.
    enum SongFields {
        case title
        case titleOrArtist
        case titleOrAlbum

        func matches(_ query: String, _ summary: TrackSummaryPresentation) -> Bool {
            switch self {
            case .title: ListFilter.matches(query, summary.title)
            case .titleOrArtist: ListFilter.matches(query, summary.title, summary.artistName)
            case .titleOrAlbum: ListFilter.matches(query, summary.title, summary.albumTitle)
            }
        }

        var prompt: String {
            switch self {
            case .title: "Songs"
            case .titleOrArtist: "Songs or artists"
            case .titleOrAlbum: "Songs or albums"
            }
        }
    }
}

/// A Filter button in the toolbar that shows a small search field above the
/// list. Closing it clears the filter. While it shows, a list hides its
/// header so the rows it narrows stay in sight.
private struct ListFilterModifier: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    var prompt: String
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: isPresented) { _, presented in
                    guard !presented else { return }
                    // Once the header is back in the list.
                    Task { @MainActor in
                        withAnimation(.smooth) { proxy.scrollTo(ListFilter.headerID, anchor: .top) }
                    }
                }
        }
        .safeAreaBar(edge: .top) {
            if isPresented { field }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.smooth) { setPresented(!isPresented) }
                } label: {
                    Label("Filter", systemImage: isPresented
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease")
                }
                .untinted()
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            Button {
                withAnimation(.smooth) { setPresented(false) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Filter")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .onAppear { isFocused = true }
    }

    private func setPresented(_ presented: Bool) {
        isPresented = presented
        if !presented {
            text = ""
            isFocused = false
        }
    }
}

extension View {
    /// See `ListFilter`.
    func listFilter(text: Binding<String>, isPresented: Binding<Bool>, prompt: String) -> some View {
        modifier(ListFilterModifier(text: text, isPresented: isPresented, prompt: prompt))
    }
}

/// Shown in place of the rows when none match.
struct ListFilterNoMatchesView: View {
    var body: some View {
        Text("No matches")
            .foregroundStyle(.secondary)
    }
}

#Preview {
    @Previewable @State var text = ""
    @Previewable @State var isFiltering = false
    NavigationStack {
        List(["Laid", "Sometimes", "Sit Down"].filter { ListFilter.matches(text, $0) }, id: \.self) { Text($0) }
            .listFilter(text: $text, isPresented: $isFiltering, prompt: "Songs or artists")
            .navigationTitle("Filter")
    }
}
