import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PlaybackController.self) private var playbackController

    /// Everything (iPhone and iPad), or one of the Mac Settings window's tabs.
    enum Pane {
        case all, general, troubleshooting

        var title: String {
            switch self {
            case .all: "Settings"
            case .general: "General"
            case .troubleshooting: "Troubleshooting"
            }
        }
    }

    @Bindable var settings: OverplaySettings
    var pane: Pane = .all
    /// The Mac Settings window sizes itself to the pane's controls, and grows
    /// while a page is pushed from them.
    var onMacContentHeight: ((CGFloat) -> Void)? = nil
    var onMacPushChange: ((Bool) -> Void)? = nil
    @State private var showResetConfirmation = false
    @State private var showNukeConfirmation = false
    @State private var showRebuildConfirmation = false
    @State private var tab = Pane.general
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.automatic
    @AppStorage(PlayerBackgroundPreference.storageKey) private var playerBackground = PlayerBackgroundPreference.art
    @State private var viewModel = SettingsViewModel()
    @AppStorage(SystemNowPlayingBridge.mirrorDefaultsKey) private var mirrorsNowPlaying = false

    var body: some View {
        Group {
            if pane == .all {
                Form {
                    switch tab {
                    case .troubleshooting: troubleshootingSections
                    default: generalSections
                    }

                    if let message = viewModel.message {
                        Section {
                            Text(message)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .safeAreaBar(edge: .top) { tabPicker }
                .miniPlayerScrollContentInset()
            } else {
                macPane
            }
        }
        // The Mac window's tabs already name the pane.
        .navigationTitle(pane == .all ? pane.title : "")
        .navigationBarTitleDisplayMode(pane == .all ? .automatic : .inline)
        .task {
            viewModel.refreshMusicKitActivityReport(dependencies: dependencies)
        }
        .onDisappear {
            viewModel.saveIfNeeded(settings: settings, context: modelContext, dependencies: dependencies)
        }
        .confirmationDialog(
            "Rebuild “\(oneTruePlaylist?.name ?? "Overplay")” in Apple Music?",
            isPresented: $showRebuildConfirmation, titleVisibility: .visible
        ) {
            Button("Rebuild Playlist") {
                Task { await viewModel.rebuildOneTruePlaylist(context: modelContext, dependencies: dependencies) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Overplay creates a new playlist with the same name, containing your active songs in Overplay’s order, and uses it from now on. Retired songs are left out. Plays, skips and history are kept. Afterwards, delete the older playlist in the Music app.")
        }
        .confirmationDialog("Reset all local stats?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Local Stats", role: .destructive) {
                resetStats()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears Overplay skip, playthrough, and retired state. It does not delete Apple Music playlist content.")
        }
        .confirmationDialog("Nuke local and iCloud data?", isPresented: $showNukeConfirmation, titleVisibility: .visible) {
            Button("Nuke Database", role: .destructive) {
                nukeDatabase()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes Overplay records locally and saves the deletions so iCloud can sync them. Apple Music playlists are not deleted.")
        }
    }

    // MARK: - iPhone and iPad tabs

    /// General settings first; the tools for when something is wrong apart.
    /// A segmented control keeps its text small; at accessibility sizes the
    /// tabs are stacked buttons that grow with the text.
    @ViewBuilder private var tabPicker: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    tabButton(.general)
                    tabButton(.troubleshooting)
                }
            } else {
                Picker("Settings", selection: $tab) {
                    Text("General").tag(Pane.general)
                    Text("Troubleshooting").tag(Pane.troubleshooting)
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func tabButton(_ pane: Pane) -> some View {
        let isSelected = tab == pane
        Button {
            tab = pane
        } label: {
            Text(pane.title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(isSelected ? .accentColor : nil)
        .fontWeight(isSelected ? .semibold : .regular)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var generalSections: some View {
        Section {
            LabeledContent {
                Text(oneTruePlaylistStatus.title)
            } label: {
                Label("One True Playlist", systemImage: "arrow.up.circle")
            }
            if let url = appleMusicURL {
                Link(destination: url) {
                    Label("Open in Apple Music", systemImage: "arrow.up.forward.app")
                }
            }
            NavigationLink {
                TriageSourcesView()
                    .nowPlayingColumnToggle()
            } label: {
                SettingsActionLabel(
                    title: "Inbox Sources",
                    subtitle: "Playlists whose new songs arrive in the Inbox for you to promote or retire.",
                    systemImage: "tray.full"
                )
            }
        } header: {
            Text("Playlists")
        } footer: {
            Text(oneTruePlaylistStatus.note)
                .font(.caption)
        }

        Section {
            NavigationLink {
                DuplicateTracksView()
                    .nowPlayingColumnToggle()
            } label: {
                SettingsActionLabel(
                    title: "Find Duplicates",
                    subtitle: "Songs that appear more than once, such as a single and its album version, for you to merge.",
                    systemImage: "square.on.square"
                )
            }
            .accessibilityIdentifier("settings-find-duplicates")
        } header: {
            Text("Library")
        }

        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
            .untinted()
            Picker("Player Background", selection: $playerBackground) {
                ForEach(PlayerBackgroundPreference.allCases) { Text($0.title).tag($0) }
            }
            .untinted()
        } header: {
            Text("Display")
        } footer: {
            Text("Automatic follows your device’s Light or Dark setting. The player shows the playing song’s album art blurred behind its controls, or just the colour picked from that art. Both apply to this device only.")
                .font(.caption)
        }

        SiriShortcutsSectionView()

        Section {
            SettingsSliderRow(
                title: "Skip threshold: \(Int(settings.skipThresholdPercentage))%",
                label: "Skip threshold",
                unit: "%",
                subtitle: "An early skip counts only if playback stops before this percentage of the track.",
                value: $settings.skipThresholdPercentage,
                range: 1...99,
                step: 1
            )

            SettingsSliderRow(
                title: "Minimum listening time: \(Int(settings.minimumSkipListeningSeconds)) seconds",
                label: "Minimum listening time",
                unit: " seconds",
                subtitle: "Playback must reach this duration before an early skip can be counted.",
                value: $settings.minimumSkipListeningSeconds,
                range: 0...60,
                step: 1
            )

            SettingsSliderRow(
                title: "Playthrough threshold: \(Int(settings.playthroughThresholdPercentage))%",
                label: "Playthrough threshold",
                unit: "%",
                subtitle: "Listening past this percentage counts as a full playthrough instead of a skip.",
                value: $settings.playthroughThresholdPercentage,
                range: 1...100,
                step: 1
            )
        } header: {
            Text("Counting Plays and Skips")
        } footer: {
            Text("Plays show the higher of Overplay’s count and Apple Music’s, which includes listening outside Overplay; when Apple’s is higher, Overplay’s count rises to match. Apple’s count may update late. These thresholds apply only to Overplay.")
                .font(.caption)
        }
    }

    @ViewBuilder private var troubleshootingSections: some View {
        Section {
            Text("Tools for when something isn’t right. You shouldn’t need them day to day.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }

        if let oneTruePlaylist, !ProcessInfo.processInfo.isMacCatalystApp {
            RebuildPlaylistSection(
                playlistName: oneTruePlaylist.name,
                editsRefused: oneTruePlaylist.remoteEditsRefusedAt != nil,
                isRebuilding: viewModel.isRebuildingPlaylist
            ) {
                showRebuildConfirmation = true
            }
        }

        Section {
            if let musicKitActivityReport = viewModel.musicKitActivityReport {
                MusicKitActivityReportView(summary: musicKitActivityReport)

                DisclosureGroup("Full Activity Report") {
                    Text(musicKitActivityReport.text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }

                Button {
                    viewModel.refreshMusicKitActivityReport(dependencies: dependencies)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                if !viewModel.activityLogFiles.isEmpty {
                    ShareLink(items: viewModel.activityLogFiles) {
                        Label("Share Activity Log", systemImage: "square.and.arrow.up")
                    }
                }

                Button(role: .destructive) {
                    viewModel.resetMusicKitActivityLog(dependencies: dependencies)
                } label: {
                    Label("Clear Recorded Activity", systemImage: "trash")
                }
            }
        } header: {
            Text("Apple Music Call Activity")
        } footer: {
            Text("Every Overplay call into Apple Music is recorded with its size, duration, and outcome, and kept across launches. Reach for this after Apple Music misbehaves system-wide. Share Activity Log sends the summary and a full log for each of the last 10 launches, as of the last refresh.")
                .font(.caption)
        }

        Section {
            Button {
                Task { await runMusicKitDiagnostics() }
            } label: {
                SettingsActionLabel(
                    title: viewModel.isRunningMusicKitDiagnostics ? "Running MusicKit Diagnostics" : "Run MusicKit Diagnostics",
                    subtitle: "Checks Apple Music authorization, playlist access, whether the One True Playlist is still editable, and playback readiness. Makes several live Apple Music requests.",
                    systemImage: "waveform.path.ecg"
                )
            }
            .disabled(viewModel.isRunningMusicKitDiagnostics)

            if let musicKitDiagnosticsReport = viewModel.musicKitDiagnosticsReport {
                Text(musicKitDiagnosticsReport)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            SettingsLabeledToggle(
                title: "Mirror Now Playing from Overplay",
                subtitle: "Diagnostic only, this device. Use it to check CarPlay on a new iOS release; normally Apple Music publishes Now Playing itself.",
                isOn: $mirrorsNowPlaying
            )
            .onChange(of: mirrorsNowPlaying) { _, isOn in
                AppRuntime.shared.nowPlayingBridge.isMirrorEnabled = isOn
            }
        } header: {
            Text("Diagnostics")
        }

        Section {
            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                SettingsActionLabel(
                    title: "Reset All Local Overplay Stats",
                    subtitle: "Resets both displayed play counts, skips, and retired state without changing Apple Music’s own counts or playlists.",
                    systemImage: "arrow.counterclockwise"
                )
            }

            Button(role: .destructive) {
                showNukeConfirmation = true
            } label: {
                SettingsActionLabel(
                    title: "Nuke Database",
                    subtitle: "Deletes all Overplay records locally and syncs those deletions through iCloud.",
                    systemImage: "trash"
                )
            }
        } header: {
            Text("Start Over")
        } footer: {
            Text("Both ask first, and neither can be undone. Your Apple Music playlists are never deleted.")
                .font(.caption)
        }
    }

    private var oneTruePlaylistStatus: OneTruePlaylistStatus { .make(settings) }

    /// The One True Playlist in the Music app's library.
    private var appleMusicURL: URL? {
        settings.selectedPlaylistID.flatMap { URL(string: "https://music.apple.com/library/playlist/\($0)") }
    }

    private var oneTruePlaylist: PlaylistRecord? {
        try? PlaylistRepository.oneTruePlaylist(in: modelContext)
    }

    private func resetStats() {
        if viewModel.resetStats(context: modelContext, dependencies: dependencies) {
            dismiss()
        }
    }

    private func nukeDatabase() {
        if viewModel.nukeDatabase(context: modelContext, dependencies: dependencies) {
            dismiss()
        }
    }

    private func runMusicKitDiagnostics() async {
        await viewModel.runMusicKitDiagnostics(
            settings: settings,
            context: modelContext,
            dependencies: dependencies
        )
    }

    private var dependencies: SettingsViewModel.Dependencies {
        .live(playbackController: playbackController)
    }
}

private struct SettingsSubtitle: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsLabeledStepper: View {
    var title: String
    var subtitle: String
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsSubtitle(subtitle)
            }

            HStack {
                Spacer()
                Stepper(value: $value, in: range) {
                    EmptyView()
                }
                .accessibilityLabel(title)
            }
        }
    }
}

private struct SettingsSliderRow: View {
    var title: String
    /// The title without its value, for VoiceOver, which reads the value.
    var label: String
    var unit: String
    var subtitle: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsSubtitle(subtitle)
            }
            // The slider carries them, so VoiceOver hears them with it.
            .accessibilityHidden(true)

            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value))\(unit)")
                .accessibilityHint(subtitle)
        }
    }
}

private struct SettingsLabeledToggle: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsSubtitle(subtitle)
            }
        }
    }
}

/// `PLAYLIST-009`: replaces the Apple Music playlist with an Overplay-made one.
private struct RebuildPlaylistSection: View {
    var playlistName: String
    var editsRefused: Bool
    var isRebuilding: Bool
    var rebuild: () -> Void

    var body: some View {
        Section {
            Button(action: rebuild) {
                if isRebuilding {
                    Label("Rebuilding “\(playlistName)”…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    SettingsActionLabel(
                        title: "Rebuild Apple Music Playlist",
                        subtitle: "Creates a new “\(playlistName)” playlist from Overplay’s active songs and uses it from now on.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
            }
            .disabled(isRebuilding)
        } header: {
            Text("Apple Music Playlist")
        } footer: {
            if editsRefused {
                Text("Apple Music won’t let Overplay remove songs from “\(playlistName)”. A rebuilt playlist is one Overplay created, so it can be edited again.")
                    .font(.caption)
            }
        }
    }
}

#Preview("Rebuild section") {
    Form {
        RebuildPlaylistSection(playlistName: "Overplay", editsRefused: true, isRebuilding: false) {}
    }
}

private struct SettingsActionLabel: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                SettingsSubtitle(subtitle)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView(settings: OverplaySettings(selectedPlaylistID: "preview-playlist", selectedPlaylistName: "Overplay"))
    }
    .modelContainer(PreviewContainer.make())
    .environment(PlaybackController())
}

// MARK: - Mac Settings window

/// A Mac settings window's layout for one pane: right-aligned labels and
/// compact controls on the window's background, as Safari's Settings, not
/// the iOS grouped list. Same settings, actions and confirmations.
extension SettingsView {
    var macPane: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 30) {
                switch pane {
                case .general: macGeneralRows
                case .troubleshooting: macTroubleshootingRows
                case .all: EmptyView()
                }
                if let message = viewModel.message {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        MacSettingsNote(message)
                    }
                }
            }
            // Both tabs start at the same margin with the same label column,
            // so the line between labels and controls does not move between
            // them.
            .padding(.leading, 24)
            .padding(.trailing, 32)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onMacContentHeight?($0) }
        }
        .background(Color(uiColor: .systemBackground))
        // The window's tabs are its header; pushed pages bring their own bar.
        .toolbar(.hidden, for: .navigationBar)
    }

    private func macPushed<Page: View>(_ page: Page) -> some View {
        page
            .onAppear { onMacPushChange?(true) }
            .onDisappear { onMacPushChange?(false) }
    }

    @ViewBuilder private var macGeneralRows: some View {
        GridRow {
            MacSettingsLabel("One True Playlist:")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(oneTruePlaylistStatus.title)
                    if let url = appleMusicURL {
                        Link("Open in Apple Music", destination: url)
                            .buttonStyle(.bordered)
                    }
                }
                MacSettingsNote(oneTruePlaylistStatus.note)
            }
        }
        GridRow {
            MacSettingsLabel("Inbox sources:")
            VStack(alignment: .leading, spacing: 6) {
                NavigationLink("Inbox Sources…") {
                    macPushed(TriageSourcesView())
                }
                .buttonStyle(.bordered)
                MacSettingsNote("Playlists whose new songs arrive in the Inbox for you to promote or retire.")
            }
        }
        GridRow {
            MacSettingsLabel("Library:")
            VStack(alignment: .leading, spacing: 6) {
                NavigationLink("Find Duplicates…") {
                    macPushed(DuplicateTracksView())
                }
                .buttonStyle(.bordered)
                MacSettingsNote("Songs that appear more than once, such as a single and its album version, for you to merge.")
            }
        }
        GridRow {
            MacSettingsLabel("Appearance:")
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
        }
        GridRow {
            MacSettingsLabel("Player background:")
            VStack(alignment: .leading, spacing: 6) {
                Picker("Player background", selection: $playerBackground) {
                    ForEach(PlayerBackgroundPreference.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                MacSettingsNote("The playing song’s album art blurred behind the player, or just the colour picked from it.")
            }
        }
        GridRow {
            MacSettingsLabel("Skip threshold:")
            MacSettingsSlider(title: "Skip threshold", value: $settings.skipThresholdPercentage, range: 1...99, unit: "%",
                              note: "An early skip counts only if playback stops before this percentage of the track.")
        }
        GridRow {
            MacSettingsLabel("Minimum listening:")
            MacSettingsSlider(title: "Minimum listening time", value: $settings.minimumSkipListeningSeconds, range: 0...60, unit: " s",
                              note: "Playback must reach this duration before an early skip can be counted.")
        }
        GridRow {
            MacSettingsLabel("Playthrough threshold:")
            MacSettingsSlider(title: "Playthrough threshold", value: $settings.playthroughThresholdPercentage, range: 1...100, unit: "%",
                              note: "Listening past this percentage counts as a full playthrough instead of a skip.")
        }
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            MacSettingsNote("Plays show the higher of Overplay’s count and Apple Music’s, which includes listening outside Overplay; when Apple’s is higher, Overplay’s count rises to match. Apple’s count may update late. These thresholds apply only to Overplay.")
        }
    }

    @ViewBuilder private var macTroubleshootingRows: some View {
        GridRow {
            MacSettingsLabel("Apple Music calls:")
            VStack(alignment: .leading, spacing: 10) {
                if let report = viewModel.musicKitActivityReport {
                    MusicKitActivityReportView(summary: report)
                    HStack(spacing: 8) {
                        Button("Refresh") { viewModel.refreshMusicKitActivityReport(dependencies: dependencies) }
                        if !viewModel.activityLogFiles.isEmpty {
                            ShareLink("Share Activity Log", items: viewModel.activityLogFiles)
                        }
                        Button("Clear Recorded Activity", role: .destructive) {
                            viewModel.resetMusicKitActivityLog(dependencies: dependencies)
                        }
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    DisclosureGroup("Full Activity Report") {
                        Text(report.text)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                MacSettingsNote("Every Overplay call into Apple Music is recorded with its size, duration, and outcome, and kept across launches. Reach for this after Apple Music misbehaves system-wide. Share Activity Log sends the summary and a full log for each of the last 10 launches, as of the last refresh.")
            }
        }
        GridRow {
            MacSettingsLabel("Diagnostics:")
            VStack(alignment: .leading, spacing: 10) {
                Button(viewModel.isRunningMusicKitDiagnostics ? "Running MusicKit Diagnostics…" : "Run MusicKit Diagnostics") {
                    Task { await runMusicKitDiagnostics() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRunningMusicKitDiagnostics)
                MacSettingsNote("Checks Apple Music authorization, playlist access, whether the One True Playlist is still editable, and playback readiness. Makes several live Apple Music requests.")
                if let report = viewModel.musicKitDiagnosticsReport {
                    Text(report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Toggle("Mirror Now Playing from Overplay", isOn: $mirrorsNowPlaying)
                    .fixedSize()
                    .onChange(of: mirrorsNowPlaying) { _, isOn in
                        AppRuntime.shared.nowPlayingBridge.isMirrorEnabled = isOn
                    }
                MacSettingsNote("Diagnostic only, this device. Use it to check CarPlay on a new iOS release; normally Apple Music publishes Now Playing itself.")
            }
        }
        GridRow {
            MacSettingsLabel("Stats:")
            VStack(alignment: .leading, spacing: 6) {
                Button("Reset All Local Stats…", role: .destructive) { showResetConfirmation = true }
                    .buttonStyle(.bordered)
                MacSettingsNote("Resets both displayed play counts, skips, and retired state without changing Apple Music’s own counts or playlists.")
            }
        }
        GridRow {
            MacSettingsLabel("Database:")
            VStack(alignment: .leading, spacing: 6) {
                Button("Nuke Database…", role: .destructive) { showNukeConfirmation = true }
                    .buttonStyle(.bordered)
                MacSettingsNote("Deletes all Overplay records locally and syncs those deletions through iCloud.")
            }
        }
        GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            MacSettingsNote("Both ask first, and neither can be undone. Your Apple Music playlists are never deleted.")
        }
    }
}

private struct MacSettingsLabel: View {
    /// Fits the longest label in any tab ("Playthrough threshold:").
    static let columnWidth: CGFloat = 180

    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.trailing)
            .frame(width: Self.columnWidth, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

private struct MacSettingsNote: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 380, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacSettingsSlider: View {
    /// For VoiceOver: the grid's label column is a separate element.
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: 1)
                    .frame(width: 220)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(value))\(unit)")
                    .accessibilityHint(note)
                Text("\(Int(value))\(unit)")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)
            }
            // The row's label lines up with the slider, which has no text.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            MacSettingsNote(note)
        }
    }
}
