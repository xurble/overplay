import SwiftUI

/// Shown with a stuck player's advice to force-quit, in place of Try Again: a
/// reminder to take a sysdiagnose first, while Overplay is still stuck (#90).
struct SysdiagnoseReminderButtonView: View {
    @Environment(PlaybackController.self) private var playbackController
    @State private var isShowingSteps = false

    var body: some View {
        if SysdiagnoseReminder.isShown(for: playbackController.playbackFailure) {
            Button {
                isShowingSteps = true
            } label: {
                Label(SysdiagnoseReminder.buttonTitle, systemImage: "stethoscope")
            }
            .buttonStyle(.glass)
            .sheet(isPresented: $isShowingSteps) {
                SysdiagnoseReminderView(device: SysdiagnoseReminder.currentDevice)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

#Preview {
    SysdiagnoseReminderButtonView()
        .environment(PlaybackController())
}
