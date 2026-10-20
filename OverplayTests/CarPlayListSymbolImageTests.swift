import CarPlay
import Testing
import UIKit
@testable import Overplay

/// CarPlay draws list images as given, so a row symbol must carry its colour
/// for both of CarPlay's appearances.
@MainActor
@Suite("CarPlay list symbols")
struct CarPlayListSymbolImageTests {
    @Test func aLabelSymbolIsLightOnDarkCarPlayAndDarkOnLight() throws {
        let image = try #require(CarPlayListSymbolImage.image(systemName: "tray.fill", color: .label))
        let dark = try #require(image.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .dark)))
        let light = try #require(image.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .light)))

        #expect(try brightness(of: dark) > 0.8)
        #expect(try brightness(of: light) < 0.2)
        #expect(image.renderingMode != .alwaysTemplate)
    }

    @Test func aColouredSymbolKeepsItsColour() throws {
        let image = try #require(CarPlayListSymbolImage.image(systemName: "tray.fill", color: .systemTeal))
        let dark = try #require(image.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .dark)))

        let (red, green, blue) = try averageColour(of: dark)
        #expect(blue > red + 0.3 && green > red + 0.3)
    }

    @Test func theSymbolFitsCarPlaysImageSlotSharply() throws {
        let image = try #require(CarPlayListSymbolImage.image(systemName: "archivebox.fill", color: .systemGray))

        #expect(image.scale == CarPlayListSymbolImage.scale)
        #expect(image.size.width <= CPListItem.maximumImageSize.width)
        #expect(image.size.height <= CPListItem.maximumImageSize.height)
        #expect(max(image.size.width / CPListItem.maximumImageSize.width,
                    image.size.height / CPListItem.maximumImageSize.height) > 0.99)
    }

    @Test func anUnknownSymbolHasNoImage() {
        #expect(CarPlayListSymbolImage.image(systemName: "not.a.real.symbol", color: .label) == nil)
    }

    // MARK: - Pixels

    private func brightness(of image: UIImage) throws -> Double {
        let (red, green, blue) = try averageColour(of: image)
        return (red + green + blue) / 3
    }

    /// The average colour of the image's opaque pixels, unpremultiplied.
    private func averageColour(of image: UIImage) throws -> (Double, Double, Double) {
        let cgImage = try #require(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = (0.0, 0.0, 0.0), count = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let alpha = Double(pixels[index + 3])
            total.0 += Double(pixels[index]) / alpha
            total.1 += Double(pixels[index + 1]) / alpha
            total.2 += Double(pixels[index + 2]) / alpha
            count += 1
        }
        try #require(count > 0)
        return (total.0 / count, total.1 / count, total.2 / count)
    }
}
