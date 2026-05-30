import Foundation
@preconcurrency import MusicKit
import Observation

enum AppleMusicReadiness: Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized(canPlayCatalogContent: Bool, hasCloudLibraryEnabled: Bool)
    case failed(String)

    var isReady: Bool {
        if case let .authorized(canPlayCatalogContent, hasCloudLibraryEnabled) = self {
            canPlayCatalogContent && hasCloudLibraryEnabled
        } else {
            false
        }
    }

    var title: String {
        switch self {
        case .notDetermined:
            "Apple Music not connected"
        case .denied:
            "Apple Music access denied"
        case .restricted:
            "Apple Music access restricted"
        case let .authorized(canPlayCatalogContent, hasCloudLibraryEnabled):
            if !canPlayCatalogContent {
                "Apple Music subscription needed"
            } else if !hasCloudLibraryEnabled {
                "Sync Library is off"
            } else {
                "Apple Music connected"
            }
        case .failed:
            "Apple Music check failed"
        }
    }

    var message: String {
        switch self {
        case .notDetermined:
            "Connect Apple Music so Overplay can read and play your selected playlist."
        case .denied:
            "Enable Media & Apple Music access for Overplay in Settings to continue."
        case .restricted:
            "This device is restricted from granting Apple Music library access."
        case let .authorized(canPlayCatalogContent, hasCloudLibraryEnabled):
            if !canPlayCatalogContent {
                "Overplay can see permission, but playback needs an active Apple Music subscription."
            } else if !hasCloudLibraryEnabled {
                "Turn on Sync Library for Apple Music so Overplay can read your playlists."
            } else {
                "Ready to pick the playlist Overplay will monitor."
            }
        case let .failed(error):
            error
        }
    }
}

@MainActor
@Observable
final class MusicAuthorizationService {
    var readiness: AppleMusicReadiness = .notDetermined
    var isLoading = false
    var hasCheckedReadiness = false

    func refresh() async {
#if targetEnvironment(simulator)
        readiness = .authorized(canPlayCatalogContent: true, hasCloudLibraryEnabled: true)
        hasCheckedReadiness = true
#else
        isLoading = true
        defer {
            isLoading = false
            hasCheckedReadiness = true
        }

        let status = MusicAuthorization.currentStatus
        switch status {
        case .notDetermined:
            readiness = .notDetermined
        case .denied:
            readiness = .denied
        case .restricted:
            readiness = .restricted
        case .authorized:
            await refreshSubscription()
        @unknown default:
            readiness = .failed("Overplay received an unknown Apple Music authorization state.")
        }
#endif
    }

    func requestAccess() async {
#if targetEnvironment(simulator)
        readiness = .authorized(canPlayCatalogContent: true, hasCloudLibraryEnabled: true)
        hasCheckedReadiness = true
#else
        isLoading = true
        defer {
            isLoading = false
            hasCheckedReadiness = true
        }

        let status = await MusicAuthorization.request()
        switch status {
        case .authorized:
            await refreshSubscription()
        case .denied:
            readiness = .denied
        case .restricted:
            readiness = .restricted
        case .notDetermined:
            readiness = .notDetermined
        @unknown default:
            readiness = .failed("Overplay received an unknown Apple Music authorization state.")
        }
#endif
    }

    private func refreshSubscription() async {
        do {
            let subscription = try await MusicSubscription.current
            readiness = .authorized(
                canPlayCatalogContent: subscription.canPlayCatalogContent,
                hasCloudLibraryEnabled: subscription.hasCloudLibraryEnabled
            )
        } catch {
            readiness = .failed(error.localizedDescription)
        }
    }
}
