import SwiftData
import SwiftUI

struct AppRouter: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(MusicAuthorizationService.self) private var authorizationService
    @Environment(PlaybackController.self) private var playbackController

    @AppStorage("overplay.hasPresentedAuthorizedUI") private var hasPresentedAuthorizedUI = false

    @Query(sort: \OverplaySettings.createdAt) private var settingsRecords: [OverplaySettings]
    @State private var playerSheetDetent: PresentationDetent = .height(96)
    @State private var startupViewModel = AppStartupViewModel()

    private let playerSheetCollapsedHeight = MiniPlayerLayout.collapsedHeight

    var body: some View {
        Group {
            if shouldShowPermissionView {
                NavigationStack {
                    PermissionView()
                }
            } else if let settings {
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
        .sheet(isPresented: playerSheetPresentation) {
            if let settings {
                PlayerSheetView(settings: settings, collapsedHeight: playerSheetCollapsedHeight)
                    .presentationDetents([.height(playerSheetCollapsedHeight), .large], selection: $playerSheetDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.clear)
                    .presentationBackgroundInteraction(.enabled(upThrough: .height(playerSheetCollapsedHeight)))
                    .presentationContentInteraction(.resizes)
                    .interactiveDismissDisabled()
            } else {
                EmptyView()
            }
        }
        .task {
            await startupViewModel.bootstrap(
                isReady: authorizationService.readiness.isReady,
                dependencies: startupDependencies
            )
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

    private var playerSheetPresentation: Binding<Bool> {
        Binding {
            authorizationService.readiness.isReady && settings != nil
        } set: { _ in
            playerSheetDetent = .height(playerSheetCollapsedHeight)
        }
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
