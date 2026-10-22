import SwiftData
import SwiftUI

struct AppRouter: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(MusicAuthorizationService.self) private var authorizationService
    @Environment(PlaybackController.self) private var playbackController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @AppStorage("overplay.hasPresentedAuthorizedUI", store: AppPersistence.libraryDefaults)
    private var hasPresentedAuthorizedUI = false

    @Query(sort: \OverplaySettings.createdAt) private var settingsRecords: [OverplaySettings]
    @State private var isPlayerExpanded = false
    /// The expanded player was hidden by a fold or a size change, so it comes
    /// back already open, as the screen activates.
    @State private var playerReturnsInPlace = false
    @State private var miniPlayerFrame: CGRect = .zero
    @State private var openDrag = PlayerOpenDrag()
    @State private var artworkPresentation = PlaylistArtworkPresentation()
    private var startupViewModel: AppStartupViewModel { runtime.startupViewModel }

    var body: some View {
        Group {
            if shouldShowPermissionView {
                NavigationStack {
                    PermissionView()
                }
            } else if startupViewModel.isSettingUp {
                SetupView {
                    startupViewModel.finishSetup(dependencies: startupDependencies)
                }
            } else if startupViewModel.isRestoringFromCloud {
                ContentUnavailableView {
                    Label("Restoring your library", systemImage: "icloud.and.arrow.down")
                } description: {
                    Text("Your Overplay library is on its way from iCloud. This can take a few minutes on a new device.")
                } actions: {
                    ProgressView()
                }
            } else if let error = startupViewModel.libraryPreparationError {
                ContentUnavailableView {
                    Label("Waiting for your library", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { startupViewModel.retryLibraryPreparation(dependencies: startupDependencies) }
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
        .environment(artworkPresentation)
        .overlay(alignment: .bottom) {
            // The layer, not the lozenge, ignores the keyboard: the overlay's
            // frame ends at the keyboard, so the lozenge would ride above it.
            // Laid out to the screen's bottom, the keyboard covers it instead.
            ZStack(alignment: .bottom) {
                Color.clear
                    .allowsHitTesting(false)
                if showsPlayer, let settings {
                    MiniPlayerLozengeView(settings: settings, onOpen: openPlayer) { distance in
                        guard distance > 0 || openDrag.progress != nil else { return }
                        openDrag.outcome = nil
                        openDrag.progress = PlayerOpenDrag.progress(draggedUp: distance, miniPlayerTop: miniPlayerFrame.minY)
                        if !isPlayerExpanded { openPlayer() }
                    } onOpenDragEnded: { value in
                        guard openDrag.progress != nil else { return }
                        let up = CGSize(width: value.translation.width, height: -value.translation.height)
                        let predictedUp = CGSize(width: value.predictedEndTranslation.width, height: -value.predictedEndTranslation.height)
                        openDrag.outcome = FullScreenPlayerView.closesPlayer(translation: up, predictedEnd: predictedUp) ? .open : .cancel
                        openDrag.progress = nil
                    }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { miniPlayerFrame = $0 }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .modifier(UnderVerticalBar())
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        .onChange(of: showsFullScreenPlayer) { _, shows in
            if !shows, isPlayerExpanded { playerReturnsInPlace = true }
        }
        // Expanded, not shown: while a folding phone is open the player is
        // hidden but stays expanded, and the closed screen must come up
        // already in landscape rather than turning to it.
        .onChange(of: isPlayerExpanded, initial: true) { _, isExpanded in
            PlayerOrientation.setFullScreenPlayerOpen(isExpanded)
        }
        // Drawn over the app rather than presented: a presentation slides in
        // whatever its transaction, and holds the iPhone's portrait-only
        // orientation as a folding phone opens. Over the app, the player is
        // simply there as a screen activates, as the system's own apps are.
        .overlay {
            if showsFullScreenPlayer, let settings {
                FullScreenPlayerView(
                    settings: settings,
                    miniPlayerFrame: miniPlayerFrame,
                    openDrag: openDrag,
                    opensInPlace: playerReturnsInPlace
                ) {
                    isPlayerExpanded = false
                }
                .accessibilityAddTraits(.isModal)
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
            // Setup creates its own library; a late import is met when it finishes.
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
        PlayerPlacement(horizontalSizeClass, verticalSizeClass) == .sheet
            && authorizationService.readiness.isReady && runtime.libraryRestoration.isReady && settings != nil
            && !startupViewModel.isPreparingLibrary && startupViewModel.libraryPreparationError == nil
            && !startupViewModel.isSettingUp
    }

    /// The player animates its own opening out of the mini player.
    private func openPlayer() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        playerReturnsInPlace = false
        withTransaction(transaction) { isPlayerExpanded = true }
    }

    /// The player stays expanded while regular width hides it, for when it
    /// returns (a folding phone closed again).
    private var showsFullScreenPlayer: Bool {
        showsPlayer && isPlayerExpanded
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


