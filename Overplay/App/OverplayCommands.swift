import SwiftUI

/// What the menu bar (and an iPad's keyboard shortcuts) can do in the
/// focused window: go to a screen, show or hide Now Playing, and the
/// transport, all through the same actions the window's own controls use.
struct ShellCommands {
    var navigate: (AppShellDestination) -> Void
    var oneTruePlaylist: AppShellDestination?
    var triage: AppShellDestination?
    var nowPlaying: NowPlayingColumnToggle?
    var playPause: () -> Void
    var next: () -> Void
    var previous: () -> Void
}

extension FocusedValues {
    @Entry var shellCommands: ShellCommands?
    /// A text field has focus: ⌘→ and ⌘← belong to it, not to Next and
    /// Previous.
    @Entry var isEditingText: Bool?
}

struct OverplayCommands: Commands {
    @FocusedValue(\.shellCommands) private var shell
    @FocusedValue(\.isEditingText) private var isEditingText
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                if ProcessInfo.processInfo.isMacCatalystApp {
                    SettingsWindowView.open(with: openWindow)
                } else {
                    shell?.navigate(.settings)
                }
            }
            .keyboardShortcut(",")
        }
        // One main window; Overplay has no documents to duplicate, move,
        // rename or export.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}

        SidebarCommands()
        CommandGroup(after: .sidebar) {
            if let nowPlaying = shell?.nowPlaying {
                Button(nowPlaying.isShown ? "Hide Now Playing" : "Show Now Playing", action: nowPlaying.toggle)
                    .keyboardShortcut("p", modifiers: [.command, .option])
            }
        }

        CommandMenu("Go") {
            go("Dashboard", .dashboard, key: "1")
            go("Overplay", shell?.oneTruePlaylist, key: "2")
            go("Inbox", shell?.triage, key: "3")
            go("Retired", .retired, key: "4")
            Divider()
            go("Search", .search, key: "f")
            go("History", .history, key: "y")
        }

        CommandMenu("Controls") {
            Button("Play/Pause") { shell?.playPause() }
                .disabled(shell == nil)
            Button("Next") { shell?.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(shell == nil || isEditingText == true)
            Button("Previous") { shell?.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(shell == nil || isEditingText == true)
        }
    }

    private func go(_ title: String, _ destination: AppShellDestination?, key: KeyEquivalent) -> some View {
        Button(title) {
            if let destination { shell?.navigate(destination) }
        }
        .keyboardShortcut(key)
        .disabled(shell == nil || destination == nil)
    }
}
