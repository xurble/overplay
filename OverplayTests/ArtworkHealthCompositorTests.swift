import CoreGraphics
import Testing
@testable import Overplay

#if os(macOS)
import AppKit

private typealias TestPlatformImage = NSImage
#else
import UIKit

private typealias TestPlatformImage = UIImage
#endif

@Suite("Artwork health compositor")
struct ArtworkHealthCompositorTests {
    @Test("composited image preserves dimensions")
    func preservesDimensions() {
        let base = makeSolidImage(size: CGSize(width: 200, height: 200), color: .blue)
        let composited = ArtworkHealthCompositor.compositedImage(
            base: base,
            health: .healthy,
            pixelSize: 200
        )

        #expect(imageSize(composited) == CGSize(width: 200, height: 200))
    }

    @Test("badge center is transparent")
    func badgeCenterIsTransparent() {
        let base = makeSolidImage(size: CGSize(width: 200, height: 200), color: .blue)
        let composited = ArtworkHealthCompositor.compositedImage(
            base: base,
            health: .healthy,
            pixelSize: 200
        )

        let badgeRect = ArtworkHealthCompositor.badgeRect(for: CGSize(width: 200, height: 200))
        let center = CGPoint(x: badgeRect.midX, y: badgeRect.midY)
        let alpha = pixelAlpha(in: composited, at: center)

        #expect(alpha < 0.05)
    }

    @Test("label ring uses health color")
    func labelRingUsesHealthColor() {
        let base = makeSolidImage(size: CGSize(width: 200, height: 200), color: .blue)
        let composited = ArtworkHealthCompositor.compositedImage(
            base: base,
            health: .caution,
            pixelSize: 200
        )

        let badgeRect = ArtworkHealthCompositor.badgeRect(for: CGSize(width: 200, height: 200))
        let samplePoint = CGPoint(
            x: badgeRect.midX + badgeRect.width * 0.20,
            y: badgeRect.midY
        )
        let components = pixelRGBA(in: composited, at: samplePoint)

        #expect(components.r > 0.8)
        #expect(components.g > 0.4)
        #expect(components.b < 0.2)
        #expect(components.a > 0.9)
    }

    private func makeSolidImage(size: CGSize, color: CGColor) -> TestPlatformImage {
        #if os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        if let context = NSGraphicsContext.current?.cgContext {
            context.setFillColor(color)
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            context.cgContext.setFillColor(color)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
        #endif
    }

    private func imageSize(_ image: TestPlatformImage) -> CGSize {
        #if os(macOS)
        image.size
        #else
        image.size
        #endif
    }

    private func pixelAlpha(in image: TestPlatformImage, at point: CGPoint) -> CGFloat {
        pixelRGBA(in: image, at: point).a
    }

    private func pixelRGBA(in image: TestPlatformImage, at point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        #if os(macOS)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return (0, 0, 0, 0)
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let x = min(max(Int(point.x), 0), width - 1)
        let y = min(max(Int(point.y), 0), height - 1)
        let flippedY = height - 1 - y
        let offset = flippedY * bytesPerRow + x * 4
        let r = CGFloat(bytes[offset]) / 255
        let g = CGFloat(bytes[offset + 1]) / 255
        let b = CGFloat(bytes[offset + 2]) / 255
        let a = CGFloat(bytes[offset + 3]) / 255
        return (r, g, b, a)
        #else
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return (0, 0, 0, 0)
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = cgImage.bytesPerRow
        let x = min(max(Int(point.x * image.scale), 0), width - 1)
        let y = min(max(Int(point.y * image.scale), 0), height - 1)
        let offset = y * bytesPerRow + x * 4
        let r = CGFloat(bytes[offset]) / 255
        let g = CGFloat(bytes[offset + 1]) / 255
        let b = CGFloat(bytes[offset + 2]) / 255
        let a = CGFloat(bytes[offset + 3]) / 255
        return (r, g, b, a)
        #endif
    }
}

private extension CGColor {
    static var blue: CGColor {
        CGColor(red: 0, green: 0, blue: 1, alpha: 1)
    }
}
