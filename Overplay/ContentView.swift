//
//  ContentView.swift
//  Overplay
//
//  Created by Gareth Simpson on 14/05/2026.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var authorizationService = MusicAuthorizationService()
    @State private var playbackController = PlaybackController()

    var body: some View {
        AppRouter()
            .environment(authorizationService)
            .environment(playbackController)
    }
}

#Preview {
    ContentView()
        .modelContainer(PreviewContainer.make())
}
