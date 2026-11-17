import CoreGraphics
import Foundation
import Testing
@testable import Overplay

/// The Mac's full-screen cover and remembered window frame: pure rules,
/// which run on every platform.
@Suite("Mac full-screen player", .serialized)
@MainActor
struct MacFullScreenPlayerTests {
    @Test func theCoverFillsTheSpaceUpToItsOwnPixels() {
        // Room for 600 points; a 3000-pixel cover at 2x would allow 1500.
        #expect(MacFullScreenArtworkView.side(maxSide: 600.7, nativePixels: 3000, scale: 2) == 600)
        // A 1000-pixel cover at 2x is never drawn larger than 500 points.
        #expect(MacFullScreenArtworkView.side(maxSide: 600, nativePixels: 1000, scale: 2) == 500)
        // Before any large cover is known, the space decides.
        #expect(MacFullScreenArtworkView.side(maxSide: 600, nativePixels: nil, scale: 2) == 600)
        #expect(MacFullScreenArtworkView.side(maxSide: -20, nativePixels: nil, scale: 2) == 0)
    }

    @Test func theCoverIsAskedForAtItsShownSizeInSteps() {
        #expect(MacFullScreenArtworkView.requestPixels(maxSide: 600, scale: 2) == 1280)
        #expect(MacFullScreenArtworkView.requestPixels(maxSide: 601, scale: 2) == 1280)
        #expect(MacFullScreenArtworkView.requestPixels(maxSide: 5000, scale: 2) == 4096)
    }

    @Test func theCoverTemplateIsFilledIn() {
        let url = MacFullScreenArtworkView.requestURL(template: "https://is1.example.com/a/{w}x{h}bb.jpg", pixels: 1280)
        #expect(url?.absoluteString == "https://is1.example.com/a/1280x1280bb.jpg")
        #expect(MacFullScreenArtworkView.requestURL(template: "not a url", pixels: 1280) == nil)
    }

    @Test func theWindowFrameIsKeptAndAnEmptyOneIgnored() {
        let key = MacWindowFrameMemory.defaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)

        #expect(MacWindowFrameMemory.savedFrame == nil)
        MacWindowFrameMemory.save(CGRect(x: 300, y: 160, width: 1200, height: 700))
        MacWindowFrameMemory.save(.zero)
        #expect(MacWindowFrameMemory.savedFrame == CGRect(x: 300, y: 160, width: 1200, height: 700))
    }
}
