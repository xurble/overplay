import Foundation
import Testing
@testable import Overplay

/// Framework errors are shown in plain words; Overplay's own pass through.
@Suite("User-facing error messages")
struct UserFacingErrorTests {
    private struct ForeignError: LocalizedError {
        var errorDescription: String? { "The operation couldn't be completed. (SomeFramework error 7.)" }
    }

    @Test("Overplay's own errors keep their message")
    func overplayErrorsPassThrough() {
        #expect(UserFacingError.friendly(SearchServiceError.resultUnavailable) == "Search result is no longer available.")
    }

    @Test("Network errors explain the connection")
    func networkErrors() {
        #expect(UserFacingError.friendly(URLError(.notConnectedToInternet)) == "You're offline. Check your connection and try again.")
        #expect(UserFacingError.friendly(URLError(.timedOut)) == "Apple Music took too long to answer. Try again.")
        #expect(UserFacingError.friendly(URLError(.cannotFindHost)) == "Couldn't reach Apple Music. Check your connection and try again.")
    }

    @Test("Apple Music framework errors are named in plain words")
    func frameworkErrors() {
        #expect(UserFacingError.friendly(NSError(domain: "MPMusicPlayerControllerErrorDomain", code: 6))
            == "Apple Music couldn't start this song. Press Play to try again.")
        #expect(UserFacingError.friendly(NSError(domain: "ICPlaylistUpdateErrorDomain", code: -1))
            == "Apple Music wouldn't change that playlist.")
        #expect(UserFacingError.friendly(NSError(domain: "ICErrorDomain", code: 3)) == "Apple Music ran into a problem. Try again.")
    }

    @Test("Any other error gets the generic message, not its framework text")
    func otherErrors() {
        #expect(UserFacingError.friendly(ForeignError()) == "Something went wrong. Try again.")
    }
}
