import CoreGraphics
import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ArtworkHealthCompositor {
    static let labelScale: CGFloat = 0.38
    static let holeScale: CGFloat = 0.12
    static let badgeWidthRatio: CGFloat = 0.234
    static let badgeInsetRatio: CGFloat = 0.04

    static func badgeRect(for imageSize: CGSize) -> CGRect {
        let badgeDiameter = imageSize.width * badgeWidthRatio
        let inset = imageSize.width * badgeInsetRatio
        return CGRect(
            x: imageSize.width - inset - badgeDiameter,
            y: inset,
            width: badgeDiameter,
            height: badgeDiameter
        )
    }

    static func drawVinylBadge(
        in context: CGContext,
        health: TrackHealthStatus,
        imageSize: CGSize
    ) {
        let badgeRect = badgeRect(for: imageSize)
        let center = CGPoint(x: badgeRect.midX, y: badgeRect.midY)
        let outerRadius = badgeRect.width / 2
        let labelRadius = outerRadius * labelScale
        let holeRadius = outerRadius * holeScale

        context.saveGState()

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.addEllipse(in: badgeRect)
        context.fillPath()

        context.setFillColor(labelColor(for: health))
        context.addEllipse(
            in: CGRect(
                x: center.x - labelRadius,
                y: center.y - labelRadius,
                width: labelRadius * 2,
                height: labelRadius * 2
            )
        )
        context.fillPath()

        context.setBlendMode(.clear)
        context.addEllipse(
            in: CGRect(
                x: center.x - holeRadius,
                y: center.y - holeRadius,
                width: holeRadius * 2,
                height: holeRadius * 2
            )
        )
        context.fillPath()

        context.restoreGState()
    }

    static func labelColor(for health: TrackHealthStatus) -> CGColor {
        switch health {
        case .healthy:
            return CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .caution:
            return CGColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1)
        case .critical:
            return CGColor(red: 1.00, green: 0.23, blue: 0.19, alpha: 1)
        }
    }
}

#if os(macOS)
extension ArtworkHealthCompositor {
    static func compositedImage(
        base: NSImage,
        health: TrackHealthStatus,
        pixelSize: Int
    ) -> NSImage {
        let imageSize = base.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return base
        }

        let result = NSImage(size: imageSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        base.draw(in: NSRect(origin: .zero, size: imageSize))
        if let context = NSGraphicsContext.current?.cgContext {
            drawVinylBadge(in: context, health: health, imageSize: imageSize)
        }
        return result
    }

}
#else
extension ArtworkHealthCompositor {
    static func compositedImage(
        base: UIImage,
        health: TrackHealthStatus,
        pixelSize: Int
    ) -> UIImage {
        let imageSize = base.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return base
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = base.scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
        return renderer.image { rendererContext in
            base.draw(in: CGRect(origin: .zero, size: imageSize))
            drawVinylBadge(in: rendererContext.cgContext, health: health, imageSize: imageSize)
        }
    }

}
#endif
