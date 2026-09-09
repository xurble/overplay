import CarPlay
import Testing
import UIKit
@testable import Overplay

@MainActor
@Suite("CarPlay Now Playing button images")
struct CarPlayNowPlayingButtonImageFactoryTests {
    @Test("uses the vehicle scale and stays within CarPlay's maximum size", arguments: [1.0, 2.0, 3.0])
    func usesVehicleScale(displayScale: CGFloat) throws {
        let traitCollection = UITraitCollection(displayScale: displayScale)
        for systemName in ["trash", "arrow.uturn.backward.circle", "star"] {
            let image = try #require(CarPlayNowPlayingButtonImageFactory.image(
                systemName: systemName,
                traitCollection: traitCollection
            ))

            #expect(image.scale == displayScale)
            #expect(image.size.width <= CPNowPlayingButtonMaximumImageSize.width)
            #expect(image.size.height <= CPNowPlayingButtonMaximumImageSize.height)
            #expect(image.renderingMode == .alwaysTemplate)
        }
    }

    @Test("scales symbols down to a smaller supplied maximum")
    func respectsSuppliedMaximum() throws {
        let maximumSize = CGSize(width: 12, height: 10)
        let image = try #require(CarPlayNowPlayingButtonImageFactory.image(
            systemName: "star",
            traitCollection: UITraitCollection(displayScale: 2),
            maximumSize: maximumSize
        ))

        #expect(image.size.width <= maximumSize.width)
        #expect(image.size.height <= maximumSize.height)
        #expect(image.scale == 2)
    }

    @Test("returns nil for an unknown symbol")
    func rejectsUnknownSymbol() {
        #expect(CarPlayNowPlayingButtonImageFactory.image(
            systemName: "not.a.real.symbol",
            traitCollection: UITraitCollection(displayScale: 2)
        ) == nil)
    }
}
