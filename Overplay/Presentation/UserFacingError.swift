import CloudKit
import Foundation
@preconcurrency import MusicKit

/// What to tell the user about an error. MusicKit, MediaPlayer and the
/// network report errors in framework terms ("Failed to prepare to play",
/// domains and codes); the raw error is logged and a plain message shown.
/// Overplay's own errors are already written for people and pass through.
@MainActor
enum UserFacingError {
    static func message(for error: Error) -> String {
        let nsError = error as NSError
        TrackMetadataDiagnostics.log(
            "user-facing error raw: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription) userInfo=\(nsError.userInfo)"
        )
        return friendly(error)
    }

    nonisolated static func friendly(_ error: Error) -> String {
        if let request = error as? MusicDataRequest.Error {
            return message(forStatus: request.status)
        }
        if error is MusicTokenRequestError {
            return "Overplay couldn't connect to Apple Music. Check Overplay's Apple Music access in Settings."
        }
        let nsError = error as NSError
        // Overplay's own errors, already written for people.
        if nsError.domain.hasPrefix("Overplay.") { return nsError.localizedDescription }
        switch nsError.domain {
        case "MPMusicPlayerControllerErrorDomain":
            return "Apple Music couldn't start this song. Press Play to try again."
        case NSURLErrorDomain:
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return "You're offline. Check your connection and try again."
            case NSURLErrorTimedOut:
                return "Apple Music took too long to answer. Try again."
            default:
                return "Couldn't reach Apple Music. Check your connection and try again."
            }
        case "ICPlaylistUpdateErrorDomain", "MPPlaylistUpdateErrorDomain":
            return "Apple Music wouldn't change that playlist."
        case CKError.errorDomain:
            return "iCloud sync ran into a problem. It will try again."
        default:
            if nsError.domain.contains("MusicKit") || nsError.domain.hasPrefix("ICError") || nsError.domain.hasPrefix("MP") {
                return "Apple Music ran into a problem. Try again."
            }
            return "Something went wrong. Try again."
        }
    }

    private nonisolated static func message(forStatus status: Int) -> String {
        switch status {
        case 401, 403: "Apple Music didn't allow that. Check Overplay's Apple Music access in Settings."
        case 404: "Apple Music couldn't find that."
        case 429: "Apple Music is busy. Try again in a moment."
        case 500...: "Apple Music is having trouble. Try again later."
        default: "Apple Music ran into a problem. Try again."
        }
    }
}
