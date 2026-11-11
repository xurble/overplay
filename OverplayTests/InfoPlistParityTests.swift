import Foundation
import Testing

/// `Config/Shared.xcconfig` keeps the iOS and Mac Catalyst Info.plists
/// identical apart from multiple scenes, which only the Mac has. A key added
/// to one file alone goes wrong only on the other platform: a missing usage
/// description, for one, ends the app when it asks for access.
///
/// Reads the source files, so it runs only where they can be read: the
/// simulator, not a device or a sandboxed Mac run.
@Suite("Info.plist parity")
struct InfoPlistParityTests {
    nonisolated private static let configDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Config")

    nonisolated private static var sourcesAreReadable: Bool {
        FileManager.default.isReadableFile(atPath: configDirectory.appending(path: "Info.plist").path)
    }

    private func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.configDirectory.appending(path: name))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("the Mac plist differs from the iOS one only by multiple scenes", .enabled(if: sourcesAreReadable))
    func macMatchesIOS() throws {
        let iOS = try plist("Info.plist")
        var mac = try plist("Info-MacCatalyst.plist")

        var sceneManifest = try #require(mac["UIApplicationSceneManifest"] as? [String: Any])
        #expect(sceneManifest.removeValue(forKey: "UIApplicationSupportsMultipleScenes") as? Bool == true)
        mac["UIApplicationSceneManifest"] = sceneManifest

        #expect(NSDictionary(dictionary: mac).isEqual(to: iOS))
    }
}
