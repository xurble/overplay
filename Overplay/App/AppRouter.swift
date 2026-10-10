import SwiftData
import SwiftUI

struct AppRouter: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(MusicAuthorizationService.self) private var authorizationService
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @AppStorage("overplay.hasPresentedAuthorizedUI") private var hasPresentedAuthorizedUI = false

    @Query(sort: \OverplaySettings.createdAt) private var settingsRecords: [OverplaySettings]
    @State private var showingNewLibraryConfirmation = false
    @State private var setupError: String?
    @State private var isPlayerExpanded = false
    @State private var miniPlayerFrame: CGRect = .zero
    @State private var artworkPresentation = PlaylistArtworkPresentation()
    private var startupViewModel: AppStartupViewModel { runtime.startupViewModel }

    var body: some View {
        Group {
            if shouldShowPermissionView {
                NavigationStack {
                    PermissionView()
                }
            } else if let error = startupViewModel.libraryPreparationError {
                ContentUnavailableView {
                    Label("Waiting for your library", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { startupViewModel.retryLibraryPreparation(dependencies: startupDependencies) }
                    if runtime.libraryRestoration.canCreateLibrary {
                        Button("Set up a new library") { showingNewLibraryConfirmation = true }
                    }
                }
            } else if startupViewModel.isPreparingLibrary {
                ProgressView("Restoring your library")
            } else if runtime.libraryRestoration.isReady, let settings {
                PlatformShell(settings: settings)
                    .onAppear {
                        hasPresentedAuthorizedUI = true
                    }
            } else {
                NavigationStack {
                    ProgressView("Preparing Overplay")
                }
            }
        }
        #if targetEnvironment(simulator)
        // Screenshots of the full player without a drag.
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-OverplayExpandedPlayer") { isPlayerExpanded = true }
        }
        #endif
        .confirmationDialog("Create a new Overplay library?", isPresented: $showingNewLibraryConfirmation) {
            Button("Create new library") {
                do {
                    try runtime.libraryRestoration.createLibrary(in: modelContext)
                    startupViewModel.retryLibraryPreparation(dependencies: startupDependencies)
                } catch { setupError = error.localizedDescription }
            }
        } message: {
            Text("Only continue if you have never set up Overplay on another device. If you already have a library, wait for iCloud to restore it.")
        }
        .alert("Could not create library", isPresented: Binding(get: { setupError != nil }, set: { if !$0 { setupError = nil } })) {
            Button("OK") { setupError = nil }
        } message: { Text(setupError ?? "") }
        .environment(artworkPresentation)
        .overlay(alignment: .bottom) {
            if showsPlayer, let settings {
                MiniPlayerLozengeView(settings: settings) { isPlayerExpanded = true }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { miniPlayerFrame = $0 }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .modifier(UnderVerticalBar())
                    .ignoresSafeArea(.keyboard)
            }
        }
        .fullScreenCover(isPresented: playerCoverPresentation) {
            if let settings {
                FullScreenPlayerView(settings: settings, miniPlayerFrame: miniPlayerFrame)
                    // Supply the same shared instances at this hosting boundary.
                    // Relying on inherited values crashed during sheet construction
                    // on My Mac (Designed for iPad).
                    .environment(playbackController)
                    .environment(runtime)
                    .environment(authorizationService)
                    .environment(artworkPresentation)
                    .modelContext(modelContext)
                    // Clear, so the app shows above the player as it is swiped down.
                    .presentationBackground(.clear)
            }
        }
        .sheet(item: $artworkPresentation.request) { request in
            PlaylistCollageSettingsView(layout: request.layout, stroke: request.stroke) { layout, stroke in
                artworkPresentation.apply(layout: layout, stroke: stroke)
            }
        }
        .task {
            await startupViewModel.bootstrap(
                isReady: authorizationService.readiness.isReady,
                dependencies: startupDependencies
            )
        }
        .onChange(of: runtime.libraryRestoration.importRevision) { _, _ in
            if authorizationService.readiness.isReady, !startupViewModel.hasStartedAuthorizedServices {
                startupViewModel.retryLibraryPreparation(dependencies: startupDependencies)
            }
        }
        .onChange(of: authorizationService.readiness.isReady) { _, isReady in
            Task {
                startupViewModel.authorizationReadinessChanged(
                    isReady: isReady,
                    dependencies: startupDependencies
                )
            }
        }
    }

    private var settings: OverplaySettings? {
        settingsRecords.first
    }

    private var shouldShowPermissionView: Bool {
        startupViewModel.shouldShowPermissionView(
            readiness: authorizationService.readiness,
            hasCheckedReadiness: authorizationService.hasCheckedReadiness,
            hasPresentedAuthorizedUI: hasPresentedAuthorizedUI
        )
    }

    /// The mini player and full-screen player belong to compact width; in
    /// regular width the player is a column beside the list instead.
    private var showsPlayer: Bool {
        PlayerPlacement(horizontalSizeClass) == .sheet
            && authorizationService.readiness.isReady && runtime.libraryRestoration.isReady && settings != nil
            && !startupViewModel.isPreparingLibrary && startupViewModel.libraryPreparationError == nil
    }

    private var playerCoverPresentation: Binding<Bool> {
        Binding {
            showsPlayer && isPlayerExpanded
        } set: { isPlayerExpanded = $0 }
    }

    private var startupDependencies: AppStartupViewModel.Dependencies {
        startupViewModel.dependencies(
            modelContext: modelContext,
            runtime: runtime,
            authorizationService: authorizationService,
            playbackController: playbackController
        )
    }
}

#Preview {
    AppRouter()
        .environment(AppRuntime.shared)
        .environment(MusicAuthorizationService())
        .environment(PlaybackController())
        .modelContainer(PreviewContainer.make())
}


