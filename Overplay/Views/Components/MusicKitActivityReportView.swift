import SwiftUI

/// Renders recorded Apple Music call activity: the flagged call patterns
/// first, then the full text for copying into a bug report.
struct MusicKitActivityReportView: View {
    var summary: MusicKitActivityReport.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MusicKitActivityHeadlineView(summary: summary)

            if summary.concerns.isEmpty {
                Label("No abusive call patterns detected.", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(summary.concerns.enumerated()), id: \.offset) { _, concern in
                    MusicKitActivityConcernRow(concern: concern)
                }
            }
        }
    }
}

struct MusicKitActivityHeadlineView: View {
    var summary: MusicKitActivityReport.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(summary.totalCalls) recorded Apple Music calls")
                .font(.subheadline.weight(.medium))
            if let observationStartedAt = summary.observationStartedAt {
                Text("Since \(observationStartedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MusicKitActivityConcernRow: View {
    var concern: MusicKitActivityReport.Concern

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(concern.title)
                    .font(.subheadline.weight(.medium))
                Text(concern.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(concern.severity.label): \(concern.title). \(concern.detail)")
    }

    private var symbolName: String {
        switch concern.severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch concern.severity {
        case .critical: .red
        case .warning: .orange
        }
    }
}

#Preview("With concerns") {
    Form {
        Section {
            MusicKitActivityReportView(summary: .preview)
        } header: {
            Text("Apple Music Call Activity")
        }
    }
}

#Preview("Clean") {
    Form {
        Section {
            MusicKitActivityReportView(
                summary: MusicKitActivityReport.Summary(
                    generatedAt: .now,
                    observationStartedAt: Date(timeIntervalSinceNow: -3_600),
                    totalCalls: 42,
                    rates: [],
                    failures: [],
                    concerns: [],
                    recentEvents: []
                )
            )
        }
    }
}

extension MusicKitActivityReport.Summary {
    /// Preview and test fixture. Kept next to the view so previews cannot
    /// depend on live Apple Music activity.
    static var preview: Self {
        MusicKitActivityReport.Summary(
            generatedAt: .now,
            observationStartedAt: Date(timeIntervalSinceNow: -7_200),
            totalCalls: 4_812,
            rates: [
                MusicKitActivityReport.OperationRate(
                    operation: .queueReplace,
                    lastMinute: 0,
                    lastFiveMinutes: 3,
                    lastHour: 11,
                    total: 27,
                    failures: 1,
                    maximumMagnitude: 1_204
                ),
                MusicKitActivityReport.OperationRate(
                    operation: .nowPlayingInfoWrite,
                    lastMinute: 58,
                    lastFiveMinutes: 290,
                    lastHour: 3_140,
                    total: 4_512,
                    failures: 0,
                    maximumMagnitude: nil
                )
            ],
            failures: [],
            concerns: [
                MusicKitActivityReport.Concern(
                    severity: .critical,
                    title: "Apple Music refused requests (rate limited)",
                    detail: "Playlist track fetch failed 4x with MusicDataRequest 429."
                ),
                MusicKitActivityReport.Concern(
                    severity: .warning,
                    title: "Very large player queue hand-offs",
                    detail: "Largest queue replacement was 1204 entries."
                )
            ],
            recentEvents: []
        )
    }
}
