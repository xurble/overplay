import SwiftUI
import Testing
@testable import Overplay

@Suite("Display preferences")
struct DisplayPreferencesTests {
    @Test("Automatic follows the system; Light and Dark force it")
    func appearanceColourSchemes() {
        #expect(AppearancePreference.automatic.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
    }

    @Test("stored values stay readable, and the defaults are Automatic and Album Art")
    func storedValues() {
        #expect(AppearancePreference(rawValue: "automatic") == .automatic)
        #expect(PlayerBackgroundPreference(rawValue: "art") == .art)
        #expect(PlayerBackgroundPreference(rawValue: "themeColour") == .themeColour)
        #expect(AppearancePreference.allCases.first == .automatic)
        #expect(PlayerBackgroundPreference.allCases.first == .art)
    }
}
