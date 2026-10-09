import SwiftUI

/// The steps for taking a sysdiagnose while the player is stuck (#90).
struct SysdiagnoseReminderView: View {
    @Environment(\.dismiss) private var dismiss

    var device: SysdiagnoseReminder.Device

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(SysdiagnoseReminder.steps(for: device).enumerated()), id: \.offset) { index, step in
                        Label(step, systemImage: "\(index + 1).circle")
                    }
                } footer: {
                    Text(SysdiagnoseReminder.explanation)
                }
            }
            .navigationTitle(SysdiagnoseReminder.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview("iPhone") {
    SysdiagnoseReminderView(device: .phone)
}

#Preview("Mac") {
    SysdiagnoseReminderView(device: .mac)
}
