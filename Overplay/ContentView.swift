@preconcurrency import MusicKit
//
//  ContentView.swift
//  Overplay
//
//  Created by Gareth Simpson on 14/05/2026.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    let runtime: AppRuntime

    var body: some View {
        AppRouter()
            .environment(runtime)
            .environment(runtime.authorizationService)
            .environment(runtime.playbackController)
            // iPhone and iPad take the app icon's purple for buttons and
            // highlights; the Mac keeps its own accent.
            .tint(ProcessInfo.processInfo.isMacCatalystApp ? nil : Color.overplayIcon)
            .modifier(StatusToastOverlay())
            // The player's messages become the toast. Left set: CarPlay reads
            // them for its own alerts.
            .onChange(of: runtime.playbackController.statusMessage) { _, message in
                StatusToast.shared.show(message)
            }
            // Library lists open at once: fill any empty one in the
            // background, once the launch quiet period is over (`LOAD-001`).
            .task {
                try? await Task.sleep(until: max(BackgroundMusicKitWorkPolicy.launchQuietEnds, .now + .seconds(5)))
                guard MusicAuthorization.currentStatus == .authorized else { return }
                await LibraryCache.shared.warmIfEmpty()
            }
    }
}

#Preview {
    ContentView(runtime: .shared)
        .modelContainer(PreviewContainer.make())
}

extension View {
    /// Toolbar buttons and pop-up menus in the label colour, as the system
    /// draws its own bar buttons such as Back (owner request, 2026-10-26).
    /// The rest of the app keeps the purple, and so do confirmation buttons,
    /// as the system tints them too. The Mac keeps its own accent.
    func untinted() -> some View {
        tint(ProcessInfo.processInfo.isMacCatalystApp ? nil : Color.primary)
    }
}

extension Color {
    /// The app icon's background (`overplay_default_icon.icon`).
    static let overplayIcon = Color(.displayP3, red: 0.53600, green: 0.17834, blue: 0.66090)
}
