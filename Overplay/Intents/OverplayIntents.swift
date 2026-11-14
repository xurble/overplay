import AppIntents
import Foundation

// Siri, Shortcuts, Spotlight and the Action button (`SIRI-001`). Each intent
// runs in the background, with the phone locked, and hands off to
// `VoiceActions`.

/// A reason Siri speaks when an action could not be done.
nonisolated struct VoiceActionError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
private enum VoiceIntentRunner {
    static func play(_ target: VoiceActions.Playlist) async throws {
        let runtime = AppRuntime.shared
        guard let context = await runtime.prepareForBackgroundAction() else {
            throw VoiceActionError(message: runtime.backgroundActionRefusal)
        }
        if let failure = await VoiceActions.play(target, controller: runtime.playbackController, context: context) {
            throw VoiceActionError(message: failure)
        }
    }

    static func curate(_ action: VoiceActions.Curation) async throws -> String {
        let runtime = AppRuntime.shared
        guard let context = await runtime.prepareForBackgroundAction() else {
            throw VoiceActionError(message: runtime.backgroundActionRefusal)
        }
        let outcome = await VoiceActions.curate(action, controller: runtime.playbackController, context: context)
        if case .failed(let message) = outcome { throw VoiceActionError(message: message) }
        return outcome.message
    }

    static func diveDeeper(_ request: PlaybackCollection.Request) async throws {
        let runtime = AppRuntime.shared
        guard let context = await runtime.prepareForBackgroundAction() else {
            throw VoiceActionError(message: runtime.backgroundActionRefusal)
        }
        if let failure = await VoiceActions.diveDeeper(request, controller: runtime.playbackController, context: context) {
            throw VoiceActionError(message: failure)
        }
    }

    static func describeCurrent() async throws -> String {
        let runtime = AppRuntime.shared
        guard let context = await runtime.prepareForBackgroundAction() else {
            throw VoiceActionError(message: runtime.backgroundActionRefusal)
        }
        return VoiceActions.describeCurrent(controller: runtime.playbackController, context: context)
    }
}

nonisolated struct PlayOneTruePlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play One True Playlist"
    static let description = IntentDescription("Shuffles your One True Playlist, or carries on with it if it is already playing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        try await VoiceIntentRunner.play(.oneTruePlaylist)
        return .result()
    }
}

nonisolated struct PlayTriageIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play the Inbox"
    static let description = IntentDescription("Shuffles the Inbox, or carries on with it if it is already playing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        try await VoiceIntentRunner.play(.triage)
        return .result()
    }
}

nonisolated struct PromoteCurrentTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Promote This Song"
    static let description = IntentDescription("Moves the song that is playing from the Inbox to your One True Playlist.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await VoiceIntentRunner.curate(.promote))")
    }
}

nonisolated struct RetireCurrentTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Retire This Song"
    static let description = IntentDescription("Retires the song that is playing and skips to the next one.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await VoiceIntentRunner.curate(.retire))")
    }
}

nonisolated struct UndoLastCurationIntent: AppIntent {
    static let title: LocalizedStringResource = "Undo Promote or Retire"
    static let description = IntentDescription("Puts back the song you last promoted or retired, within 10 minutes.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await VoiceIntentRunner.curate(.undo))")
    }
}

nonisolated struct RestoreCurrentTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Restore This Song"
    static let description = IntentDescription("Moves the retired song that is playing back to the Inbox.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await VoiceIntentRunner.curate(.restore))")
    }
}

nonisolated struct AddCurrentTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Add This Song"
    static let description = IntentDescription("Adds the song playing from an album or artist to the Inbox.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await VoiceIntentRunner.curate(.add))")
    }
}

nonisolated struct PlayCurrentAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play This Album"
    static let description = IntentDescription("Plays the album of the song that is playing, from its first track.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        try await VoiceIntentRunner.diveDeeper(.album)
        return .result()
    }
}

nonisolated struct PlayCurrentArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play This Artist"
    static let description = IntentDescription("Plays the Essentials or top songs of the artist of the song that is playing.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult {
        try await VoiceIntentRunner.diveDeeper(.artist)
        return .result()
    }
}

nonisolated struct DescribeCurrentTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "What's This Song"
    static let description = IntentDescription("Says the song that is playing, where it is in Overplay, and how often you've played and skipped it.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await VoiceIntentRunner.describeCurrent())")
    }
}

/// Every phrase must name the app; that is Apple's rule for App Shortcuts.
/// Apple allows 10 App Shortcuts; these are all 10.
nonisolated struct OverplayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayOneTruePlaylistIntent(), phrases: [
            // First is the primary phrase. On iOS 27 Siri never runs this for
            // "Play/Shuffle Overplay", so these avoid both words; all three
            // worked by voice (2026-11-14). "Start Overplaying" matches the
            // first through the alternative app name in Info.plist.
            "Start \(.applicationName)",
            "Put on \(.applicationName)",
            "\(.applicationName) my music",
            "Play \(.applicationName)",
            "Shuffle \(.applicationName)",
            "Play my One True Playlist in \(.applicationName)",
        ], shortTitle: "Play One True Playlist", systemImageName: "play.fill")
        AppShortcut(intent: PlayTriageIntent(), phrases: [
            // Play-free first, as above. "Start Overplaying the Inbox" matches
            // the fourth through the alternative app name.
            "Start \(.applicationName) Inbox",
            "Start the Inbox in \(.applicationName)",
            "Put on the Inbox in \(.applicationName)",
            "Start \(.applicationName) the Inbox",
            "Play \(.applicationName) Inbox",
            "Play the Inbox on \(.applicationName)",
            "Play the Inbox in \(.applicationName)",
            "Shuffle \(.applicationName) Inbox",
        ], shortTitle: "Play the Inbox", systemImageName: "tray.full")
        AppShortcut(intent: PromoteCurrentTrackIntent(), phrases: [
            "Promote this in \(.applicationName)",
            "\(.applicationName) promote this",
            "Promote this song in \(.applicationName)",
        ], shortTitle: "Promote This Song", systemImageName: "arrow.up.circle")
        AppShortcut(intent: RetireCurrentTrackIntent(), phrases: [
            "Retire this in \(.applicationName)",
            "\(.applicationName) retire this",
            "Retire this song in \(.applicationName)",
        ], shortTitle: "Retire This Song", systemImageName: "archivebox")
        AppShortcut(intent: UndoLastCurationIntent(), phrases: [
            "Undo that in \(.applicationName)",
            "\(.applicationName) undo that",
            "Undo in \(.applicationName)",
        ], shortTitle: "Undo Promote or Retire", systemImageName: "arrow.uturn.backward")
        AppShortcut(intent: RestoreCurrentTrackIntent(), phrases: [
            "Restore this in \(.applicationName)",
            "\(.applicationName) restore this",
            "Restore this song in \(.applicationName)",
        ], shortTitle: "Restore This Song", systemImageName: "arrow.uturn.up")
        AppShortcut(intent: AddCurrentTrackIntent(), phrases: [
            "Add this to \(.applicationName)",
            "\(.applicationName) add this",
            "Add this song to \(.applicationName)",
            "Save this to \(.applicationName)",
        ], shortTitle: "Add This Song", systemImageName: "plus.circle")
        // No "Play": iOS 27 Siri gives "Play …" requests to Apple Music.
        AppShortcut(intent: PlayCurrentAlbumIntent(), phrases: [
            "Dive into this album in \(.applicationName)",
            "Start this album in \(.applicationName)",
            "\(.applicationName) this album",
        ], shortTitle: "Play This Album", systemImageName: "square.stack")
        AppShortcut(intent: PlayCurrentArtistIntent(), phrases: [
            "Dive into this artist in \(.applicationName)",
            "Start this artist in \(.applicationName)",
            "\(.applicationName) this artist",
        ], shortTitle: "Play This Artist", systemImageName: "music.mic")
        AppShortcut(intent: DescribeCurrentTrackIntent(), phrases: [
            "What's this in \(.applicationName)",
            "What is this in \(.applicationName)",
            "\(.applicationName) what's this",
            "What's playing in \(.applicationName)",
        ], shortTitle: "What's This Song", systemImageName: "info.circle")
    }
}
