import AppIntents
import SwiftUI

/// What to say to Siri, and a way into Overplay's actions in Shortcuts
/// (`SIRI-001`). Nothing needs installing: iOS registers the phrases with
/// the app, so this is only for finding them.
struct SiriShortcutsSectionView: View {
    static let phrases: [(phrase: String, systemImage: String)] = [
        ("Start Overplaying", "play.fill"),
        ("Start Overplay Inbox", "tray.full"),
        ("Promote this in Overplay", "arrow.up.circle"),
        ("Retire this in Overplay", "archivebox"),
        ("Undo that in Overplay", "arrow.uturn.backward"),
        ("Restore this in Overplay", "arrow.uturn.up"),
        ("Add this to Overplay", "plus.circle"),
        ("Dive into this album in Overplay", "square.stack"),
        ("Dive into this artist in Overplay", "music.mic"),
        ("What's this in Overplay", "info.circle"),
    ]

    var body: some View {
        Section {
            ForEach(Self.phrases, id: \.phrase) { item in
                Label {
                    Text("\u{201C}\(item.phrase)\u{201D}")
                } icon: {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(.tint)
                }
            }
            ShortcutsLink()
                .shortcutsLinkStyle(.automatic)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        } header: {
            Text("Siri & Shortcuts")
        } footer: {
            Text("Say these to Siri, with your phone locked or in CarPlay. In Shortcuts you can add them to the Action button or the Home Screen.")
                .font(.caption)
        }
    }
}

#Preview {
    Form {
        SiriShortcutsSectionView()
    }
}
