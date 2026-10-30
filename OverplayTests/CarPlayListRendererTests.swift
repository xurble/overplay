import CarPlay
import Testing
import UIKit
@testable import Overplay

@MainActor
@Suite("Stable CarPlay lists", .serialized)
struct CarPlayListRendererTests {
    @Test("unchanged refreshes retain rows, sections and artwork without writes")
    func unchangedRefreshesAreSilent() async throws {
        var writes: [MusicKitActivityOperation] = []
        var loads = 0
        let renderer = CarPlayListRenderer(loadArtwork: { _ in
            loads += 1
            return UIImage(systemName: "music.note")
        }, record: { operation, _ in writes.append(operation) })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Library", sections: [])
        let state = CarPlayListPresentation(sections: [.init(id: "root", rows: [
            .init(id: "main", title: "Main", detail: "3 tracks", artwork: .symbol("music.note"))
        ])])
        renderer.update(state, on: template, actions: [:])
        let deadline = ContinuousClock.now + .seconds(2)
        while !writes.contains(.carPlayArtworkUpdate), ContinuousClock.now < deadline { await Task.yield() }
        #expect(loads == 1)
        let row = try #require(renderer.items["main"])
        let section = try #require(template.sections.first)
        #expect(row.image != nil)
        writes.removeAll()
        for _ in 0..<20 { renderer.update(state, on: template, actions: [:]) }
        await Task.yield()
        #expect(writes.isEmpty)
        #expect(loads == 1)
        #expect(renderer.items["main"] === row)
        #expect(template.sections.first === section)
        #expect(row.image != nil)
    }

    @Test("counts and current indicators mutate retained rows; membership changes only replace sections")
    func targetedChanges() throws {
        var details: [String] = []
        let renderer = CarPlayListRenderer(record: { _, detail in details.append(detail) })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Tracks", sections: [])
        var state = CarPlayListPresentation(sections: [.init(id: "tracks", rows: [
            .init(id: "one", title: "One", detail: "0 plays", isPlaying: true),
            .init(id: "two", title: "Two", detail: "0 plays")
        ])])
        renderer.update(state, on: template, actions: [:])
        let first = try #require(renderer.items["one"])
        let second = try #require(renderer.items["two"])
        let section = try #require(template.sections.first)
        details.removeAll()
        state.sections[0].rows[0].detail = "1 play"
        state.sections[0].rows[0].isPlaying = false
        state.sections[0].rows[1].isPlaying = true
        renderer.update(state, on: template, actions: [:])
        #expect(template.sections.first === section)
        #expect(renderer.items["one"] === first)
        #expect(renderer.items["two"] === second)
        #expect(first.detailText == "1 play")
        #expect(!first.isPlaying && second.isPlaying)
        #expect(details.count == 2)
        #expect(!details.contains { $0.hasPrefix("sections") })
        state.sections[0].rows.removeFirst()
        renderer.update(state, on: template, actions: [:])
        #expect(renderer.items["one"] == nil)
        #expect(renderer.items["two"] === second)
        #expect(details.last == "sections rows=1")
    }

    @Test("stale artwork completion cannot overwrite a newer row request")
    func staleArtworkIsIgnored() async throws {
        var continuation: CheckedContinuation<UIImage?, Never>?
        var artworkWrites = 0
        let renderer = CarPlayListRenderer(loadArtwork: { artwork in
            if artwork == .symbol("old") {
                return await withCheckedContinuation { continuation = $0 }
            }
            return UIImage(systemName: "star")
        }, record: { operation, _ in if operation == .carPlayArtworkUpdate { artworkWrites += 1 } })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Library", sections: [])
        var state = CarPlayListPresentation(sections: [.init(id: "root", rows: [
            .init(id: "main", title: "Main", artwork: .symbol("old"))
        ])])
        renderer.update(state, on: template, actions: [:])
        let deadline = ContinuousClock.now + .seconds(2)
        while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        let pending = try #require(continuation)
        state.sections[0].rows[0].artwork = .symbol("new")
        renderer.update(state, on: template, actions: [:])
        pending.resume(returning: UIImage(systemName: "music.note"))
        while artworkWrites == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(artworkWrites == 1)
        #expect(renderer.items["main"]?.image != nil)
    }

    @Test("a track list's header carries the list's art, title, count and an icon-only shuffle button")
    func headerIsApplied() async throws {
        var details: [String] = []
        var loaded: [CarPlayListPresentation.Row.Artwork] = []
        let renderer = CarPlayListRenderer(loadArtwork: { artwork in
            loaded.append(artwork)
            return UIImage(systemName: "star")
        }, record: { _, detail in details.append(detail) })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Overplay", sections: [])
        let art = CarPlayListPresentation.Row.Artwork.track(url: "https://example.com/{w}x{h}.jpg", playlistID: "p", size: 512)
        var state = CarPlayListPresentation(
            header: .init(title: "Overplay", subtitle: "2 tracks", artwork: art, shuffleActionID: "shuffle", canShuffle: true),
            sections: [.init(id: "tracks", rows: [
                .init(id: "one", title: "One", artwork: .symbol("music.note")),
                .init(id: "two", title: "Two")
            ])]
        )
        renderer.update(state, on: template, actions: ["shuffle": {}])

        let header = try #require(template.listHeader as? CPListTemplateDetailsHeader)
        #expect(header.title == "Overplay")
        #expect(header.subtitle == "2 tracks")
        #expect(header.wantsAdaptiveBackgroundStyle)
        let button = try #require(header.actionButtons.first)
        #expect(header.actionButtons.count == 1)
        #expect(button.title == nil)
        #expect(button.isEnabled)
        #expect(template.sections.map { $0.items.count } == [2])

        // The header's art loads first, then is applied to a new header.
        let deadline = ContinuousClock.now + .seconds(2)
        while loaded.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(loaded.first == art)
        #expect(template.listHeader !== header)

        // An unchanged refresh leaves the header alone; an empty list disables Shuffle.
        details.removeAll()
        renderer.update(state, on: template, actions: ["shuffle": {}])
        #expect(!details.contains("header"))
        state.header?.canShuffle = false
        renderer.update(state, on: template, actions: ["shuffle": {}])
        #expect(details.contains("header"))
        let disabled = try #require((template.listHeader as? CPListTemplateDetailsHeader)?.actionButtons.first)
        #expect(!disabled.isEnabled)

        state.header = nil
        renderer.update(state, on: template, actions: [:])
        #expect(template.listHeader == nil)
        #expect(details.last == "header cleared")
    }

    @Test("a list waits for its header art before a push, and a header arriving mid-push waits for the push to end")
    func headerIsNotReplacedDuringAPush() async throws {
        var details: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let renderer = CarPlayListRenderer(loadArtwork: { _ in
            await withCheckedContinuation { release = $0 }
            return UIImage(systemName: "star")
        }, record: { _, detail in details.append(detail) })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Overplay", sections: [])
        let art = CarPlayListPresentation.Row.Artwork.track(url: "https://example.com/{w}x{h}.jpg", playlistID: "p", size: 512)
        renderer.update(CarPlayListPresentation(
            header: .init(title: "Overplay", subtitle: "2 tracks", artwork: art, shuffleActionID: "shuffle", canShuffle: true),
            sections: [.init(id: "tracks", rows: [.init(id: "one", title: "One")])]
        ), on: template, actions: [:])
        let placeholder = try #require(template.listHeader)

        // The art never arrives in time: the wait ends at its limit.
        let started = ContinuousClock.now
        await renderer.headerArtwork(within: .milliseconds(100))
        #expect(ContinuousClock.now - started >= .milliseconds(100))

        // The push starts; the art lands mid-push and is held until it ends.
        renderer.holdHeaderChanges()
        details.removeAll()
        try #require(release).resume()
        try await Task.sleep(for: .milliseconds(100))
        #expect(template.listHeader === placeholder)
        renderer.releaseHeaderChanges()
        #expect(template.listHeader !== placeholder)
        #expect(details == ["header"])

        // Settled art ends the wait at once.
        let again = ContinuousClock.now
        await renderer.headerArtwork(within: .seconds(2))
        #expect(ContinuousClock.now - again < .milliseconds(500))
    }

    @Test("the playing indicator sits over the row art, as in Music")
    func playingIndicatorIsLeading() throws {
        let renderer = CarPlayListRenderer(record: { _, _ in })
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Tracks", sections: [])
        renderer.update(CarPlayListPresentation(sections: [.init(id: "tracks", rows: [
            .init(id: "one", title: "One", isPlaying: true)
        ])]), on: template, actions: [:])
        let item = try #require(renderer.items["one"])
        #expect(item.isPlaying)
        #expect(item.playingIndicatorLocation == .leading)
    }

    /// Blue art at the size the badge tests use.
    private func blueArt(_ loaded: @escaping @MainActor (CarPlayListPresentation.Row.Artwork) -> Void)
        -> @MainActor (CarPlayListPresentation.Row.Artwork) async -> UIImage? {
        { artwork in
            loaded(artwork)
            return UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            }
        }
    }

    @Test("on iOS 27 a playing row shows CarPlay's own indicator, not the badge; cards and tiles keep it")
    func systemIndicatorReplacesTheBadgeOnRows() async throws {
        var loads = 0
        let renderer = CarPlayListRenderer(loadArtwork: blueArt { _ in loads += 1 }, record: { _, _ in },
                                           badgesRows: false)
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Tracks", sections: [])
        typealias Row = CarPlayListPresentation.Row
        let art = Row.Artwork.track(url: "a", playlistID: "p")
        renderer.update(.init(sections: [.init(id: "list", rows: [
            Row(id: "card", title: "Card", isPlaying: true, artwork: .track(url: "c", playlistID: "p"), style: .card),
            Row(id: "row", title: "Row", isPlaying: true, artwork: art),
            Row(id: "strip", title: "Strip", style: .strip([
                .init(id: "tile", title: "Tile", artwork: .track(url: "t", playlistID: "p"), isPlaying: true),
            ])),
        ])]), on: template, actions: [:])
        let deadline = ContinuousClock.now + .seconds(2)
        while loads < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))

        let item = try #require(renderer.items["row"])
        #expect(item.isPlaying)
        #expect(try !hasPlayingBadge(try #require(item.image)))
        let card = try #require(renderer.imageRows["card"]?.elements.first?.image)
        #expect(try hasPlayingBadge(card, displayed: CPListImageRowItemCardElement.maximumImageSize))
        let tile = try #require(renderer.imageRows["strip"]?.elements.first?.image)
        #expect(try hasPlayingBadge(tile, displayed: CPListImageRowItemRowElement.maximumImageSize))
    }

    @Test("starting or stopping the player marks the playing rows again, and only those still playing")
    func playbackStateChangeReplaysThePlayingIndicator() async throws {
        var details: [String] = []
        let renderer = CarPlayListRenderer(record: { _, detail in details.append(detail) }, badgesRows: false)
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Overplay", sections: [])
        func state(playing: String?) -> CarPlayListPresentation {
            .init(sections: [.init(id: "list", rows: [
                .init(id: "inbox", title: "Inbox", isPlaying: playing == "inbox"),
                .init(id: "retired", title: "Retired", isPlaying: playing == "retired"),
            ])])
        }
        renderer.update(state(playing: "inbox"), on: template, actions: [:])
        let inbox = try #require(renderer.items["inbox"])
        let retired = try #require(renderer.items["retired"])

        renderer.playbackStateChanged()
        // Unmarked at once, marked again on the next turn.
        #expect(!inbox.isPlaying)
        try await Task.sleep(for: .milliseconds(50))
        #expect(inbox.isPlaying)
        #expect(!retired.isPlaying)
        #expect(details.last == "rows=inbox fields=playing-replayed")

        // A row that stopped playing in between is not marked again, nor
        // named in the log the car check reads.
        let beforeSkip = details.filter { $0.hasSuffix("playing-replayed") }.count
        renderer.playbackStateChanged()
        renderer.update(state(playing: "retired"), on: template, actions: [:])
        try await Task.sleep(for: .milliseconds(50))
        #expect(!inbox.isPlaying)
        #expect(retired.isPlaying)
        #expect(details.filter { $0.hasSuffix("playing-replayed") }.count == beforeSkip)

        // Nothing playing: nothing to replay.
        renderer.update(state(playing: nil), on: template, actions: [:])
        let recorded = details.count
        renderer.playbackStateChanged()
        try await Task.sleep(for: .milliseconds(50))
        #expect(details.count == recorded)
    }

    @Test("where the badge marks playing rows (iOS 26), starting or stopping the player leaves them alone")
    func badgedRowsAreNotReplayed() async throws {
        var details: [String] = []
        let renderer = CarPlayListRenderer(record: { _, detail in details.append(detail) }, badgesRows: true)
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Overplay", sections: [])
        renderer.update(.init(sections: [.init(id: "list", rows: [
            .init(id: "inbox", title: "Inbox", isPlaying: true),
        ])]), on: template, actions: [:])
        let inbox = try #require(renderer.items["inbox"])
        let recorded = details.count

        renderer.playbackStateChanged()
        #expect(inbox.isPlaying)
        try await Task.sleep(for: .milliseconds(50))
        #expect(inbox.isPlaying)
        #expect(details.count == recorded)
    }

    @Test("playing art carries the phone's green play badge, on rows, cards and tiles; symbols do not")
    func playingArtCarriesTheBadge() async throws {
        var loaded: [CarPlayListPresentation.Row.Artwork] = []
        // Real art is larger than any slot: on art smaller than a tile the
        // badge is a few pixels wide at 2x, and its white arrow blurs away.
        let side: CGFloat = 160
        let renderer = CarPlayListRenderer(loadArtwork: { artwork in
            loaded.append(artwork)
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            }
        }, record: { _, _ in }, badgesRows: true)
        defer { renderer.stop() }
        let template = CPListTemplate(title: "Tracks", sections: [])
        typealias Row = CarPlayListPresentation.Row
        func art(_ name: String) -> Row.Artwork { .track(url: name, playlistID: "p") }
        func state(playing: String?) -> CarPlayListPresentation {
            CarPlayListPresentation(sections: [.init(id: "list", rows: [
                Row(id: "card", title: "Card", isPlaying: playing == "card", artwork: art("card"), style: .card),
                Row(id: "row", title: "Row", isPlaying: playing == "row", artwork: art("row")),
                Row(id: "symbol", title: "Triage", isPlaying: playing == "symbol", artwork: .symbol("tray")),
                Row(id: "strip", title: "Strip", style: .strip([
                    .init(id: "tile", title: "Tile", artwork: art("tile"), isPlaying: playing == "tile"),
                ])),
            ])])
        }
        func settle(loads: Int) async {
            let deadline = ContinuousClock.now + .seconds(2)
            while loaded.count < loads, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        func badged(_ image: UIImage?, displayed: CGSize = CPListItem.maximumImageSize) throws -> Bool {
            try hasPlayingBadge(try #require(image), displayed: displayed)
        }
        let tileSize = CPListImageRowItemRowElement.maximumImageSize
        let cardSize = CPListImageRowItemCardElement.maximumImageSize

        renderer.update(state(playing: "row"), on: template, actions: [:])
        await settle(loads: 4)
        // The loader is asked for the art itself; the badge is drawn over it.
        #expect(loaded.map { "\($0)" }.sorted() == [art("card"), art("row"), .symbol("tray"), art("tile")].map { "\($0)" }.sorted())
        let item = try #require(renderer.items["row"])
        #expect(try badged(item.image))

        // The badge moves at once, over the art already loaded: a rebuilt
        // strip or card carries the right image, with nothing reloaded.
        loaded.removeAll()
        renderer.update(state(playing: "tile"), on: template, actions: [:])
        #expect(try !badged(item.image))
        let strip = try #require(renderer.imageRows["strip"])
        #expect(try badged(strip.elements.first?.image, displayed: tileSize))

        renderer.update(state(playing: "card"), on: template, actions: [:])
        let card = try #require(renderer.imageRows["card"])
        #expect(try badged(card.elements.first?.image, displayed: cardSize))
        #expect(try !badged(renderer.imageRows["strip"]?.elements.first?.image, displayed: tileSize))

        // A symbol row shows playing in its symbol, chosen by the list.
        renderer.update(state(playing: "symbol"), on: template, actions: [:])
        #expect(try !badged(renderer.imageRows["card"]?.elements.first?.image, displayed: cardSize))
        await settle(loads: 1)
        #expect(loaded.isEmpty)
    }

    @Test("on larger art the badge is as large on screen as on a row's art")
    func badgeKeepsItsScreenSize() {
        let row = CPListItem.maximumImageSize
        let art = CGSize(width: 300, height: 300)
        let shown = CGSize(width: row.width * 3, height: row.height * 3)
        let onRow = CarPlayPlayingBadge.circle(in: art).width / art.width * row.width
        let onTile = CarPlayPlayingBadge.circle(in: art, displayed: shown).width / art.width * shown.width
        #expect(abs(onRow - onTile) < 0.01)
        #expect(CarPlayPlayingBadge.circle(in: art, displayed: .zero) == CarPlayPlayingBadge.circle(in: art))
    }

    @Test("a badge with no art still shows what is playing")
    func badgeWithoutArt() throws {
        let image = CarPlayPlayingBadge.image(over: nil)
        #expect(image.size == CPListItem.maximumImageSize)
        #expect(try hasPlayingBadge(image))
    }

    /// A green circle at the bottom-trailing corner with white at its centre.
    private func hasPlayingBadge(_ image: UIImage, displayed: CGSize = CPListItem.maximumImageSize) throws -> Bool {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        func pixel(_ point: CGPoint) -> (Double, Double, Double) {
            // Memory rows run top-down, as UIKit's coordinates do.
            let index = (Int(point.y * image.scale) * width + Int(point.x * image.scale)) * 4
            return (Double(pixels[index]) / 255, Double(pixels[index + 1]) / 255, Double(pixels[index + 2]) / 255)
        }
        let circle = CarPlayPlayingBadge.circle(in: image.size, displayed: displayed)
        let edge = pixel(CGPoint(x: circle.midX - circle.width * 0.38, y: circle.midY))
        // The arrow's shaft is thin, so the exact centre may fall on its
        // anti-aliased edge: look for white just around it.
        let reach = circle.width * 0.1
        let offsets = stride(from: -reach, through: reach, by: reach / 2)
        let whitest = offsets.flatMap { dx in offsets.map { dy in
            let near = pixel(CGPoint(x: circle.midX + dx, y: circle.midY + dy))
            return min(near.0, near.1, near.2)
        } }.max() ?? 0
        let isGreen = edge.1 > 0.6 && edge.0 < 0.4 && edge.2 < 0.5
        let isWhite = whitest > 0.85
        return isGreen && isWhite
    }
}
