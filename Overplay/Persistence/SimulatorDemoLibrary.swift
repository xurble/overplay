#if targetEnvironment(simulator)
import Foundation
import SwiftData
import UIKit

/// A sample library for the simulator, where there is no Apple Music library
/// or iCloud data: enough playlists, Triage and Retired songs to exercise
/// navigation and layout. Seeded only into the empty local simulator store
/// (`AppPersistence`). A copy of a real device store placed there instead is
/// left alone, which also brings its artwork links.
enum SimulatorDemoLibrary {
    static func seedIfEmpty(_ context: ModelContext) {
        guard (try? LibraryRestorationService.isEmpty(in: context)) == true else { return }

        let otp = PlaylistRecord(musicPlaylistID: "p.simulator-overplay", name: "Overplay", role: .oneTruePlaylist)
        let bucket = PlaylistRecord(
            musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
            name: PlaylistRecord.triageBucketName, role: .triageBucket, writePolicy: .incomingOnly
        )
        let source = PlaylistRecord(musicPlaylistID: "p.simulator-new-music", name: "New Music Mix", role: .triageSource)
        let settings = OverplaySettings(selectedPlaylistID: otp.musicPlaylistID, selectedPlaylistName: otp.name)
        [otp, bucket, source].forEach(context.insert)
        context.insert(settings)

        let artists = SimulatorDemoArtwork.artists
        func track(_ index: Int, _ title: String) -> TrackRecord {
            let album = index % artists.count
            let track = TrackRecord(
                catalogID: "sim-\(index)", libraryID: "i.sim-\(index)", title: title,
                artistName: artists[album], albumTitle: SimulatorDemoArtwork.albums[album],
                artworkURLTemplate: SimulatorDemoArtwork.template(album: album),
                durationSeconds: Double(180 + index * 7 % 120)
            )
            context.insert(track)
            return track
        }

        // Fictional songs, so screenshots show no real artist. UI tests rely
        // on 12 songs in Overplay, including "Teardrop".
        let otpTitles = ["Night Bus Home", "Low Orbit", "Teardrop", "Paper Weather", "Tidal Hours", "Grow Lights",
                         "Glasshouse", "Satellite Hearts", "Kitchen Disco", "Small Hours", "Halfway to Brighton", "Slow Burn"]
        for (index, title) in otpTitles.enumerated() {
            context.insert(PlaylistItemRecord(
                playlistID: otp.id, trackID: track(index, title).id, sortOrder: index,
                skipCount: index % 3, playthroughCount: index * 2 % 7, lastSeenInPlaylistAt: .now
            ))
        }

        let triageTitles = ["Your Ex's Favourite", "Static Bloom", "Seaside in Winter", "Second Hand Sunshine",
                            "Last Train Out", "Motorway Lullaby", "Borrowed Records", "Wallpaper Song"]
        for (offset, title) in triageTitles.enumerated() {
            let index = otpTitles.count + offset
            let retired = offset >= triageTitles.count - 3
            context.insert(PlaylistItemRecord(
                playlistID: bucket.id, trackID: track(index, title).id,
                sourceMusicPlaylistIDs: [source.musicPlaylistID], sortOrder: offset,
                skipCount: retired ? 2 : 0, lastSeenInPlaylistAt: .now,
                evictedAt: retired ? .now : nil,
                evictionReason: retired ? .manual : nil,
                evictionSource: retired ? .user : nil
            ))
        }
        try? context.save()
    }
}

/// Cover art for the sample library, drawn on the device: its links name a
/// reserved host that `ArtworkCacheService` answers locally, never the network.
nonisolated enum SimulatorDemoArtwork {
    static let host = "simulator-artwork.overplay.invalid"
    static let artists = ["The Lantern Club", "Velvet Static", "Mara Quill", "Saltmarsh", "Neon Allotment", "Regret FM"]
    static let albums = ["Night Bus Home", "Low Orbit", "Paper Weather", "Tidal Hours", "Grow Lights", "Small Hours"]

    static func template(album: Int) -> String { "https://\(host)/cover/\(album)/{w}x{h}bb.png" }

    /// The PNG for a sample cover link, or nil for any other URL.
    static func png(for url: URL) -> Data? {
        guard url.host() == host, url.pathComponents.count > 2, url.pathComponents[1] == "cover",
              let album = Int(url.pathComponents[2]) else { return nil }
        return render(album: album)
    }

    private static let palettes: [(UIColor, UIColor, UIColor)] = [
        (UIColor(red: 0.05, green: 0.08, blue: 0.25, alpha: 1), UIColor(red: 0.02, green: 0.55, blue: 0.60, alpha: 1), UIColor(red: 1.00, green: 0.82, blue: 0.35, alpha: 1)),
        (UIColor(red: 0.04, green: 0.02, blue: 0.10, alpha: 1), UIColor(red: 0.45, green: 0.15, blue: 0.70, alpha: 1), UIColor(red: 0.95, green: 0.60, blue: 0.90, alpha: 1)),
        (UIColor(red: 0.96, green: 0.92, blue: 0.84, alpha: 1), UIColor(red: 0.60, green: 0.78, blue: 0.92, alpha: 1), UIColor(red: 0.20, green: 0.28, blue: 0.45, alpha: 1)),
        (UIColor(red: 0.05, green: 0.30, blue: 0.50, alpha: 1), UIColor(red: 0.40, green: 0.75, blue: 0.80, alpha: 1), UIColor(red: 0.98, green: 0.90, blue: 0.75, alpha: 1)),
        (UIColor(red: 0.55, green: 0.05, blue: 0.40, alpha: 1), UIColor(red: 0.10, green: 0.45, blue: 0.25, alpha: 1), UIColor(red: 0.70, green: 1.00, blue: 0.60, alpha: 1)),
        (UIColor(red: 0.95, green: 0.40, blue: 0.20, alpha: 1), UIColor(red: 0.85, green: 0.15, blue: 0.45, alpha: 1), UIColor(red: 1.00, green: 0.95, blue: 0.85, alpha: 1))
    ]

    private static func render(album: Int) -> Data {
        let size: CGFloat = 512
        let (top, bottom, accent) = palettes[album % palettes.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).pngData { context in
            let cg = context.cgContext
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
            accent.setFill()
            accent.setStroke()
            switch album % palettes.count {
            case 0: // headlights in the rain
                for (x, y, r) in [(170.0, 300.0, 46.0), (342.0, 300.0, 46.0)] {
                    accent.withAlphaComponent(0.25).setFill()
                    cg.fillEllipse(in: CGRect(x: x - r * 2, y: y - r * 2, width: r * 4, height: r * 4))
                    accent.setFill()
                    cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            case 1: // a ringed planet
                cg.fillEllipse(in: CGRect(x: 156, y: 156, width: 200, height: 200))
                cg.setLineWidth(14)
                cg.strokeEllipse(in: CGRect(x: 60, y: 226, width: 392, height: 60))
                for i in 0..<40 {
                    let x = CGFloat((i * 97) % 512), y = CGFloat((i * 61) % 512)
                    cg.fillEllipse(in: CGRect(x: x, y: y, width: 4, height: 4))
                }
            case 2: // folded paper stripes
                for i in 0..<7 {
                    accent.withAlphaComponent(0.15 + CGFloat(i) * 0.1).setFill()
                    cg.fill(CGRect(x: 0, y: 96 + CGFloat(i) * 46, width: size, height: 22))
                }
            case 3: // waves
                cg.setLineWidth(18)
                for row in 0..<6 {
                    let path = UIBezierPath()
                    let baseline = 150 + CGFloat(row) * 56
                    path.move(to: CGPoint(x: 0, y: baseline))
                    for x in stride(from: 0, through: size, by: 8) {
                        path.addLine(to: CGPoint(x: x, y: baseline + 18 * sin(x / 40 + CGFloat(row))))
                    }
                    accent.withAlphaComponent(1 - CGFloat(row) * 0.13).setStroke()
                    path.lineWidth = 14
                    path.stroke()
                }
            case 4: // a grid of grow lights
                for row in 0..<6 {
                    for column in 0..<6 {
                        let r = 10 + CGFloat((row + column) % 3) * 8
                        cg.fillEllipse(in: CGRect(x: 66 + CGFloat(column) * 76 - r, y: 66 + CGFloat(row) * 76 - r,
                                                  width: r * 2, height: r * 2))
                    }
                }
            default: // a disco square
                cg.setLineWidth(12)
                for i in 0..<6 {
                    let inset = 56 + CGFloat(i) * 34
                    accent.withAlphaComponent(1 - CGFloat(i) * 0.14).setStroke()
                    cg.stroke(CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2))
                }
            }
        }
    }
}
#endif
