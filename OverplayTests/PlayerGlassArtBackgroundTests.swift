import SwiftUI
import Testing
import UIKit
@testable import Overplay

/// Theme text reads the art under it through `PlayerGlassBackdrop.artFrame`.
/// The host supplies the backdrop only once a theme exists, usually after the
/// art background has laid out at its final size.
@MainActor
@Suite("Player glass art background")
struct PlayerGlassArtBackgroundTests {
    @Test("a backdrop supplied after layout still gets the art frame", .timeLimit(.minutes(1)))
    func backdropSuppliedAfterLayoutGetsArtFrame() async {
        let slot = BackdropSlot()
        let size = CGSize(width: 400, height: 800)
        let host = UIHostingController(rootView: BackdropHarness(slot: slot))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        await settle(host) { slot.isLaidOut }
        // A few more turns, so the background has surely reported its size.
        var turns = 0
        await settle(host) { turns += 1; return turns > 10 }
        let backdrop = PlayerGlassBackdrop()
        slot.backdrop = backdrop
        await settle(host) { backdrop.artFrame != .zero }

        #expect(backdrop.artFrame == PlayerGlassArtBackground.artFrame(for: size, fullHeight: size.height))
    }

    /// Lets SwiftUI update and lay out until `condition` holds, or a bounded
    /// number of turns pass.
    private func settle(_ host: UIViewController, until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
        }
    }
}

@MainActor
@Observable
private final class BackdropSlot {
    var backdrop: PlayerGlassBackdrop?
    var isLaidOut = false
}

private struct BackdropHarness: View {
    let slot: BackdropSlot

    var body: some View {
        PlayerGlassArtBackground(tint: .black)
            .environment(\.playerGlassBackdrop, slot.backdrop)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if size != .zero { slot.isLaidOut = true }
            }
            .ignoresSafeArea()
    }
}
