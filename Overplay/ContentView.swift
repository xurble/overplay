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
    }
}

#Preview {
    ContentView(runtime: .shared)
        .modelContainer(PreviewContainer.make())
}
