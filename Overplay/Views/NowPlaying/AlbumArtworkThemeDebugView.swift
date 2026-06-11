import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AlbumArtworkThemeDebugButton: View {
    var artworkTheme: AlbumArtworkTheme?
    var isLoading: Bool
    var action: () -> Void

    private var controlPalette: FullScreenPlayerControlPalette? {
        artworkTheme.flatMap(FullScreenPlayerControlPalette.init(theme:))
    }

    var body: some View {
        Button(action: action) {
            Label(isLoading ? "Analysing" : "Colours", systemImage: isLoading ? "arrow.triangle.2.circlepath" : "paintpalette")
                .symbolEffect(.rotate, options: .repeating, value: isLoading)
        }
        .fullScreenPlayerControlStyle(
            palette: controlPalette,
            prominence: .secondary,
            fallbackTint: .accentColor,
            fallbackStyle: .bordered
        )
        .disabled(isLoading)
    }
}

struct AlbumArtworkThemeDebugSheet: View {
    var report: AlbumArtworkThemeDebugReport?
    var isLoading: Bool
    var errorMessage: String?
    var onRefresh: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var didCopyReport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isLoading, report == nil {
                        loadingView
                    }

                    if let errorMessage {
                        DebugSection(title: "Problem", systemImage: "exclamationmark.triangle") {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let report {
                        reportContent(report)
                    }
                }
                .padding(20)
            }
            .background(debugBackground)
            .navigationTitle("Colour Inspector")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let report {
                        Button {
                            copyToClipboard(report.clipboardSummary)
                            didCopyReport = true
                        } label: {
                            Label(didCopyReport ? "Copied" : "Copy", systemImage: didCopyReport ? "checkmark" : "doc.on.doc")
                        }
                    }
                    Button {
                        onRefresh()
                    } label: {
                        Label("Rerun", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .onChange(of: report) { _, _ in
                didCopyReport = false
            }
            .overlay(alignment: .top) {
                if isLoading, report != nil {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Re-running artwork colour extraction")
                .font(.headline)
            Text("The player keeps using the current theme while this diagnostic pass samples OCR, palettes, contrast, and final colour decisions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func reportContent(_ report: AlbumArtworkThemeDebugReport) -> some View {
        DebugSection(title: "Chosen Theme", systemImage: "sparkles") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                ThemeSwatch(
                    label: "Background",
                    color: report.theme.backgroundRGB,
                    background: report.theme.backgroundRGB
                )
                ThemeSwatch(
                    label: "Title",
                    color: report.theme.trackTitleRGB,
                    background: report.theme.backgroundRGB
                )
                ThemeSwatch(
                    label: "Artist",
                    color: report.theme.artistNameRGB,
                    background: report.theme.backgroundRGB
                )
                ThemeSwatch(
                    label: "Album",
                    color: report.theme.albumNameRGB,
                    background: report.theme.backgroundRGB
                )
            }

            HStack(spacing: 10) {
                DebugBadge(text: report.theme.source.rawValue)
                DebugBadge(text: report.theme.isFallback ? "fallback" : "generated")
                if let hash = report.artworkDataHash?.prefix(8) {
                    DebugBadge(text: "hash \(hash)")
                }
            }

            PlayerThemePreview(theme: report.theme)
        }

        DebugSection(title: "Decision Trail", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(report.decisions.enumerated()), id: \.offset) { index, decision in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(report.theme.trackTitle)
                            .frame(width: 22, height: 22)
                            .background(report.theme.trackTitle.opacity(0.16), in: Circle())
                        Text(decision)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }

        ocrSection(report)
        paletteSection(
            title: "Candidate Palette",
            systemImage: "camera.filters",
            entries: report.cleanedPalette,
            background: report.theme.backgroundRGB,
            note: "These are analysed artwork colours. The player does not use all of them; it uses the chosen theme above after contrast and readability adjustments."
        )
        paletteSection(
            title: "Candidate Text Colours",
            systemImage: "textformat",
            entries: report.textCandidates,
            background: report.theme.backgroundRGB,
            note: "These survived the background-distance filter before the final title accent was selected or adjusted."
        )
        paletteSection(
            title: "Raw Extracted Palette",
            systemImage: "circle.grid.3x3.fill",
            entries: report.rawPalette,
            background: report.theme.backgroundRGB,
            note: "Raw clustered colours before duplicate merging and usability filters."
        )
        metricsSection(report)
    }

    private func ocrSection(_ report: AlbumArtworkThemeDebugReport) -> some View {
        DebugSection(title: "OCR", systemImage: "text.viewfinder") {
            VStack(alignment: .leading, spacing: 12) {
                Text(report.ocr.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let matchedText = report.ocr.matchedText {
                    HStack(spacing: 10) {
                        DebugBadge(text: report.ocr.matchedKind?.debugLabel ?? "matched text")
                        DebugBadge(text: matchedText)
                        if let confidence = report.ocr.matchedConfidence {
                            DebugBadge(text: "confidence \(String(format: "%.2f", Double(confidence)))")
                        }
                    }
                }

                if let sampledTextColor = report.ocr.sampledTextColor {
                    ThemeSwatch(
                        label: "OCR chosen colour",
                        color: sampledTextColor,
                        background: report.theme.backgroundRGB
                    )
                }

                if !report.ocr.localPalette.isEmpty {
                    Text("Local text-box palette")
                        .font(.subheadline.weight(.semibold))
                    swatchGrid(entries: report.ocr.localPalette, background: report.theme.backgroundRGB)
                }

                if !report.ocr.observations.isEmpty {
                    Text("Recognized text")
                        .font(.subheadline.weight(.semibold))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(report.ocr.observations.prefix(10).enumerated()), id: \.offset) { _, observation in
                            HStack {
                                Text(observation.text)
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Text(String(format: "%.2f", Double(observation.confidence)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func paletteSection(
        title: String,
        systemImage: String,
        entries: [AlbumArtworkThemeDebugPaletteEntry],
        background: AlbumArtworkRGBColor,
        note: String
    ) -> some View {
        DebugSection(title: title, systemImage: systemImage) {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)

            if entries.isEmpty {
                Text("No colours in this stage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                swatchGrid(entries: entries, background: background)
            }
        }
    }

    private func metricsSection(_ report: AlbumArtworkThemeDebugReport) -> some View {
        DebugSection(title: "Run Details", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                DebugMetricRow(label: "Generated", value: report.generatedAt.formatted(date: .omitted, time: .standard))
                DebugMetricRow(label: "Artwork bytes", value: report.artworkByteCount.formatted())
                if let size = report.downsampledSize {
                    DebugMetricRow(label: "Downsampled", value: "\(size.width)x\(size.height)")
                }
                if let size = report.croppedSize {
                    DebugMetricRow(label: "Cropped", value: "\(size.width)x\(size.height)")
                }
                if let monochrome = report.monochrome {
                    DebugMetricRow(label: "Monochrome", value: monochrome.isMonochrome ? "yes" : "no")
                    DebugMetricRow(label: "Avg saturation", value: monochrome.averageSaturation.debugNumber)
                    DebugMetricRow(label: "Neutral share", value: monochrome.neutralShare.debugNumber)
                    DebugMetricRow(label: "Chromatic share", value: monochrome.chromaticShare.debugNumber)
                }
                if let backgroundCandidate = report.backgroundCandidate {
                    DebugMetricRow(label: "Background candidate", value: backgroundCandidate.debugSummary)
                }
                if let preferredAccent = report.preferredAccent {
                    DebugMetricRow(label: "Preferred accent", value: preferredAccent.debugSummary)
                }
                if let selectedAccent = report.selectedAccent {
                    DebugMetricRow(label: "Selected accent", value: selectedAccent.debugSummary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Normalized targets")
                    .font(.subheadline.weight(.semibold))
                ForEach(report.normalizedTargets, id: \.label) { target in
                    DebugMetricRow(
                        label: target.label,
                        value: target.normalized.isEmpty ? "empty" : target.normalized
                    )
                }
            }
        }
    }

    private func swatchGrid(
        entries: [AlbumArtworkThemeDebugPaletteEntry],
        background: AlbumArtworkRGBColor
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                PaletteSwatch(entry: entry, background: background)
            }
        }
    }

    private var debugBackground: some View {
        LinearGradient(
            colors: [
                Color.primary.opacity(0.035),
                Color.secondary.opacity(0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(.background)
        .ignoresSafeArea()
    }
}

private struct DebugSection<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct PlayerThemePreview: View {
    var theme: AlbumArtworkTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approximate player treatment")
                .font(.subheadline.weight(.semibold))

            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(theme.background)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Track title")
                        .font(.title3.bold())
                        .foregroundStyle(theme.trackTitle)
                    Text("Artist name")
                        .font(.headline)
                        .foregroundStyle(theme.artistName)
                    Text("Album name")
                        .font(.subheadline)
                        .foregroundStyle(theme.albumName)

                    HStack(spacing: 10) {
                        PreviewControl(label: "Keep", theme: theme, prominence: .secondary)
                        PreviewControl(label: "Shuffle", theme: theme, prominence: .selected)
                    }
                }
                .padding(16)
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

private struct PreviewControl: View {
    var label: String
    var theme: AlbumArtworkTheme
    var prominence: FullScreenPlayerControlProminence

    private var palette: FullScreenPlayerControlPalette? {
        FullScreenPlayerControlPalette(theme: theme)
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .fullScreenPlayerGlassBackdrop(palette, shape: Capsule(), prominence: prominence)
            .foregroundStyle(prominence == .selected ? theme.background : theme.trackTitle)
    }
}

private struct ThemeSwatch: View {
    var label: String
    var color: AlbumArtworkRGBColor
    var background: AlbumArtworkRGBColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color.color)
                .frame(height: 78)
                .overlay(alignment: .bottomLeading) {
                    Text(color.hexString)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(color.readableForeground)
                        .padding(8)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                }

            Text(label)
                .font(.subheadline.weight(.semibold))
            Text(color.metricSummary(against: background))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct PaletteSwatch: View {
    var entry: AlbumArtworkThemeDebugPaletteEntry
    var background: AlbumArtworkRGBColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(entry.color.color)
                .frame(height: 52)
                .overlay(alignment: .bottomLeading) {
                    Text(entry.color.hexString)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(entry.color.readableForeground)
                        .padding(6)
                }
            Text("pop \(entry.population)")
                .font(.caption.monospacedDigit())
            Text(entry.color.metricSummary(against: background))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DebugBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct DebugMetricRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}

private extension AlbumArtworkRGBColor {
    var hexString: String {
        let red = Int((r * 255).rounded())
        let green = Int((g * 255).rounded())
        let blue = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    var readableForeground: Color {
        AlbumArtworkRGBColor.white.contrastRatio(against: self) >= AlbumArtworkRGBColor.black.contrastRatio(against: self)
            ? .white
            : .black
    }

    var debugSummary: String {
        "\(hexString) l \(relativeLuminance.debugNumber) s \(saturation.debugNumber)"
    }

    func metricSummary(against background: AlbumArtworkRGBColor) -> String {
        "l \(relativeLuminance.debugNumber) s \(saturation.debugNumber) c \(contrastRatio(against: background).debugNumber)"
    }

    func clipboardSummary(against background: AlbumArtworkRGBColor? = nil) -> String {
        var summary = "\(hexString) rgb(\(channelString(r)),\(channelString(g)),\(channelString(b))) lum=\(relativeLuminance.debugNumber) sat=\(saturation.debugNumber)"
        if let background {
            summary += " contrast=\(contrastRatio(against: background).debugNumber)"
        }
        return summary
    }

    private func channelString(_ value: CGFloat) -> String {
        Int((value * 255).rounded()).formatted()
    }
}

private extension CGFloat {
    var debugNumber: String {
        String(format: "%.3f", Double(self))
    }
}

private extension AlbumArtworkThemeDebugPaletteEntry {
    func clipboardLine(background: AlbumArtworkRGBColor) -> String {
        "pop=\(population) \(color.clipboardSummary(against: background))"
    }
}

private extension AlbumArtworkThemeDebugReport {
    var clipboardSummary: String {
        let background = theme.backgroundRGB
        var lines: [String] = []
        lines.append("Overplay album artwork theme debug")
        lines.append("generated=\(generatedAt.formatted(date: .numeric, time: .standard))")
        lines.append("source=\(theme.source.rawValue) fallback=\(theme.isFallback)")
        if let normalizedArtworkURL {
            lines.append("artworkURL=\(normalizedArtworkURL)")
        }
        if let artworkDataHash {
            lines.append("artworkHash=\(artworkDataHash)")
        }
        lines.append("artworkBytes=\(artworkByteCount)")
        if let downsampledSize {
            lines.append("downsampled=\(downsampledSize.width)x\(downsampledSize.height)")
        }
        if let croppedSize {
            lines.append("cropped=\(croppedSize.width)x\(croppedSize.height)")
        }
        if let errorMessage {
            lines.append("error=\(errorMessage)")
        }

        lines.append("")
        lines.append("Final theme")
        lines.append("background=\(theme.backgroundRGB.clipboardSummary())")
        lines.append("title=\(theme.trackTitleRGB.clipboardSummary(against: background))")
        lines.append("artist=\(theme.artistNameRGB.clipboardSummary(against: background))")
        lines.append("album=\(theme.albumNameRGB.clipboardSummary(against: background))")
        if let backgroundCandidate {
            lines.append("backgroundCandidate=\(backgroundCandidate.clipboardSummary(against: background))")
        }
        if let storedBackground = self.background {
            lines.append("reportedBackground=\(storedBackground.clipboardSummary())")
        }
        if let preferredAccent {
            lines.append("preferredAccent=\(preferredAccent.clipboardSummary(against: background))")
        }
        if let selectedAccent {
            lines.append("selectedAccent=\(selectedAccent.clipboardSummary(against: background))")
        }

        if let monochrome {
            lines.append("")
            lines.append("Monochrome")
            lines.append("isMonochrome=\(monochrome.isMonochrome)")
            lines.append("averageSaturation=\(monochrome.averageSaturation.debugNumber)")
            lines.append("neutralShare=\(monochrome.neutralShare.debugNumber)")
            lines.append("chromaticShare=\(monochrome.chromaticShare.debugNumber)")
        }

        lines.append("")
        lines.append("OCR")
        lines.append("status=\(ocr.status)")
        if let matchedKind = ocr.matchedKind {
            lines.append("matchedKind=\(matchedKind.debugLabel)")
        }
        if let matchedText = ocr.matchedText {
            lines.append("matchedText=\(matchedText)")
        }
        if let matchedConfidence = ocr.matchedConfidence {
            lines.append("matchedConfidence=\(matchedConfidence.debugNumber)")
        }
        if let sampledTextColor = ocr.sampledTextColor {
            lines.append("sampledTextColor=\(sampledTextColor.clipboardSummary(against: background))")
        }
        if let localBackgroundColor = ocr.localBackgroundColor {
            lines.append("localBackgroundColor=\(localBackgroundColor.clipboardSummary())")
        }
        if !ocr.localPalette.isEmpty {
            lines.append("localPalette:")
            lines.append(contentsOf: ocr.localPalette.prefix(10).map { "  \($0.clipboardLine(background: background))" })
        }
        if !ocr.observations.isEmpty {
            lines.append("recognizedText:")
            lines.append(contentsOf: ocr.observations.prefix(12).map {
                "  text=\"\($0.text)\" confidence=\($0.confidence.debugNumber) box=\($0.boundingBox.debugDescription)"
            })
        }

        if !normalizedTargets.isEmpty {
            lines.append("")
            lines.append("Normalized targets")
            lines.append(contentsOf: normalizedTargets.map {
                "\($0.label): original=\"\($0.original ?? "")\" normalized=\"\($0.normalized)\""
            })
        }

        lines.append("")
        lines.append("Decision trail")
        if decisions.isEmpty {
            lines.append("none")
        } else {
            lines.append(contentsOf: decisions.enumerated().map { index, decision in
                "\(index + 1). \(decision)"
            })
        }

        appendPalette("Cleaned palette", cleanedPalette, to: &lines, background: background)
        appendPalette("Text candidates", textCandidates, to: &lines, background: background)
        appendPalette("Raw palette", rawPalette, to: &lines, background: background)

        return lines.joined(separator: "\n")
    }

    private func appendPalette(
        _ title: String,
        _ entries: [AlbumArtworkThemeDebugPaletteEntry],
        to lines: inout [String],
        background: AlbumArtworkRGBColor
    ) {
        lines.append("")
        lines.append(title)
        if entries.isEmpty {
            lines.append("none")
        } else {
            lines.append(contentsOf: entries.prefix(12).map { $0.clipboardLine(background: background) })
        }
    }
}
