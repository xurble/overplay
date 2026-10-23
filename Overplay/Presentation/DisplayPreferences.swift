import SwiftUI

/// The app's light or dark appearance, chosen in Settings; per device.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case automatic, light, dark

    static let storageKey = "overplay.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// What the full player draws behind its controls; per device.
enum PlayerBackgroundPreference: String, CaseIterable, Identifiable {
    /// The album art, blurred, over the theme colour.
    case art
    /// The playing track's theme colour alone.
    case themeColour

    static let storageKey = "overplay.playerBackground"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .art: "Album Art"
        case .themeColour: "Theme Colour"
        }
    }
}

/// Applies the chosen appearance to a window's content.
struct AppearancePreferenceModifier: ViewModifier {
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.automatic

    func body(content: Content) -> some View {
        content.preferredColorScheme(appearance.colorScheme)
    }
}

extension View {
    func appliesAppearancePreference() -> some View {
        modifier(AppearancePreferenceModifier())
    }
}
