import AuthenticationServices
import Foundation
import SwiftData

enum SpotifyAuthorizationError: LocalizedError {
    case notConfigured
    case cancelled
    case missingAuthorizationCode
    case missingVerifier

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Spotify is not configured. Add a Spotify client ID to your build settings."
        case .cancelled:
            "Spotify sign-in was cancelled."
        case .missingAuthorizationCode:
            "Spotify did not return an authorization code."
        case .missingVerifier:
            "Spotify sign-in state was lost. Try again."
        }
    }
}

@MainActor
final class SpotifyAuthorizationService: NSObject {
    private let apiClient: SpotifyAPIClient
    private var pendingVerifier: String?
    private var authSession: ASWebAuthenticationSession?

    init(apiClient: SpotifyAPIClient = SpotifyAPIClient()) {
        self.apiClient = apiClient
        super.init()
    }

    var isConfigured: Bool {
        SpotifyConfiguration.isConfigured
    }

    func isConnected(in context: ModelContext) throws -> Bool {
        guard let credentials = try SpotifyCredentialsRepository.credentials(in: context) else {
            return false
        }
        return credentials.hasAccessToken
    }

    func displayName(in context: ModelContext) throws -> String? {
        try SpotifyCredentialsRepository.credentials(in: context)?.displayName
    }

    func signIn(in context: ModelContext) async throws {
        guard SpotifyConfiguration.isConfigured else {
            throw SpotifyAuthorizationError.notConfigured
        }

        let verifier = SpotifyPKCE.generateVerifier()
        pendingVerifier = verifier

        let challenge = SpotifyPKCE.challenge(for: verifier)
        var components = URLComponents(url: SpotifyConfiguration.authorizationURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: SpotifyConfiguration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyConfiguration.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: "playlist-read-private playlist-read-collaborative")
        ]

        guard let authorizationURL = components?.url else {
            throw SpotifyAuthorizationError.notConfigured
        }

        let callbackURL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "overplay"
            ) { callbackURL, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: SpotifyAuthorizationError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: SpotifyAuthorizationError.missingAuthorizationCode)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            session.start()
        }

        authSession = nil

        guard let verifier = pendingVerifier else {
            throw SpotifyAuthorizationError.missingVerifier
        }
        pendingVerifier = nil

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value else {
            throw SpotifyAuthorizationError.missingAuthorizationCode
        }

        let tokenResponse = try await apiClient.exchangeAuthorizationCode(code, verifier: verifier)
        let profile = try await apiClient.fetchCurrentUser(accessToken: tokenResponse.access_token)
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))

        try SpotifyCredentialsRepository.upsert(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresAt: expiresAt,
            scope: tokenResponse.scope ?? "",
            spotifyUserID: profile.id,
            displayName: profile.display_name ?? profile.id,
            in: context
        )
        try context.save()
    }

    func signOut(in context: ModelContext) throws {
        try SpotifyCredentialsRepository.delete(in: context)
        try context.save()
    }

    func validAccessToken(in context: ModelContext) async throws -> String {
        guard var credentials = try SpotifyCredentialsRepository.credentials(in: context) else {
            throw SpotifyAPIError.notAuthorized
        }

        if credentials.isAccessTokenValid {
            return credentials.accessToken
        }

        guard credentials.canRefresh else {
            throw SpotifyAPIError.notAuthorized
        }

        let tokenResponse = try await apiClient.refreshAccessToken(credentials.refreshToken)
        let expiresAt = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in))
        credentials = try SpotifyCredentialsRepository.upsert(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token ?? credentials.refreshToken,
            expiresAt: expiresAt,
            scope: tokenResponse.scope ?? credentials.scope,
            spotifyUserID: credentials.spotifyUserID,
            displayName: credentials.displayName,
            in: context
        )
        try context.save()
        return credentials.accessToken
    }
}

extension SpotifyAuthorizationService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
        #endif
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif
