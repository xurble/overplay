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
            throw VoiceActionError(message: VoiceActions.notReadyMessage)
        }
        if let failure = await VoiceActions.play(target, controller: runtime.playbackController, context: context) {
            throw VoiceActionError(message: failure)
        }
    }

    static func curate(_ action: VoiceActions.Curation) async throws -> String {
        let runtime = AppRuntime.shared
        guard let context = await runtime.prepareForBackgroundAction() else {
            throw VoiceActionError(message: VoiceActions.notReadyMessage)
        }
        let outcome = await VoiceActions.curate(action, controller: runtime.playbackController, context: context)
        if case .failed(let message) = outcome { throw VoiceActionError(message: message) }
        return outcome.message
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
    static let title: LocalizedStringResource = "Play Triage"
    static let description = IntentDescription("Shuffles Triage, or carries on with it if it is already playing.")
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
    static let description = IntentDescription("Moves the song that is playing from Triage to your One True Playlist.")
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

/// Every phrase must name the app; that is Apple's rule for App Shortcuts.
nonisolated struct OverplayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayOneTruePlaylistIntent(), phrases: [
            "Play \(.applicationName)",
            "Shuffle \(.applicationName)",
            "Play my One True Playlist in \(.applicationName)",
        ], shortTitle: "Play One True Playlist", systemImageName: "play.fill")
        AppShortcut(intent: PlayTriageIntent(), phrases: [
            "Play \(.applicationName) Triage",
            "Play Triage on \(.applicationName)",
            "Play Triage in \(.applicationName)",
            "Shuffle \(.applicationName) Triage",
        ], shortTitle: "Play Triage", systemImageName: "tray.full")
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
    }
}
