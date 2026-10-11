enum PlayCountPresentation {
    /// The higher of Overplay's and Apple's play counts, and the skips.
    static func plays(overplay: Int, apple: Int?) -> Int {
        max(overplay, apple ?? 0)
    }

    static func metric(overplay: Int, apple: Int?, skips: Int) -> String {
        let plays = plays(overplay: overplay, apple: apple)
        let playText = plays == 1 ? "1 play" : "\(plays) plays"
        let skipText = skips == 1 ? "1 skip" : "\(skips) skips"
        return "\(playText) · \(skipText)"
    }

    static func accessibilityLabel(overplay: Int, apple: Int?, skips: Int) -> String {
        let plays = plays(overplay: overplay, apple: apple)
        return "\(plays) \(plays == 1 ? "play" : "plays"), \(skips) \(skips == 1 ? "skip" : "skips")"
    }
}
