import ImageIO
import Photos
import UniformTypeIdentifiers

/// Saves a playlist's collage to Photos, add-only, so it can be chosen as the
/// playlist's artwork in the Music app: Apple Music has no API to set it.
enum CollagePhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .denied: "Overplay can't add to Photos. Allow it in Settings → Overplay → Photos."
            case .encodingFailed: "Overplay couldn't prepare the artwork."
            }
        }
    }

    /// The image as drawn, full size, as a PNG.
    nonisolated static func save(_ image: CGImage) async throws {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { throw SaveError.denied }
        guard let data = pngData(image) else { throw SaveError.encodingFailed }
        // The library runs the change block on its own queue.
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    nonisolated private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
