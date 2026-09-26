import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated func artworkTestData() -> Data {
    let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

nonisolated func artworkDimensions(at url: URL) throws -> [Int] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw URLError(.cannotDecodeContentData) }
    return [width, height]
}

actor ArtworkDownloadCounter {
    var value = 0
    func increment() { value += 1 }
}
