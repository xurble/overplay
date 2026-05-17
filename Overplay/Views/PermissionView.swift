import SwiftUI

struct PermissionView: View {
    @Environment(MusicAuthorizationService.self) private var authorizationService

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 36)

            VStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(.pink)
                Text("Overplay")
                    .font(.largeTitle.bold())
                Text("Keep your main playlist fresh.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label(authorizationService.readiness.title, systemImage: "apple.logo")
                    .font(.headline)
                Text(authorizationService.readiness.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button {
                Task { await authorizationService.requestAccess() }
            } label: {
                Label("Connect Apple Music", systemImage: "music.quarternote.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(authorizationService.isLoading)

            if authorizationService.isLoading {
                ProgressView()
            }

            Spacer()
        }
        .padding()
        .task {
            await authorizationService.refresh()
        }
    }
}

#Preview {
    PermissionView()
        .environment(MusicAuthorizationService())
}
