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
            // Buttons are untinted on iPhone and iPad, as the system draws its
            // own bar buttons such as Back (owner request, 2026-10-26); the
            // Mac keeps its own accent.
            .tint(ProcessInfo.processInfo.isMacCatalystApp ? nil : Color.primary)
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
