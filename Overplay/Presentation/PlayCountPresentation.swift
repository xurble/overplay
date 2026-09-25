enum PlayCountPresentation {
    static func metric(overplay: Int, apple: Int?, skips: Int) -> String {
        let appleText = apple.map(String.init) ?? "—"
        let skipText = skips == 1 ? "1 skip" : "\(skips) skips"
        return "\(overplay)/\(appleText) plays · \(skipText)"
    }

    static func accessibilityLabel(overplay: Int, apple: Int?, skips: Int) -> String {
        let appleText = apple.map { "\($0) Apple Music plays" } ?? "Apple Music plays unavailable"
        return "\(overplay) Overplay plays, \(appleText), \(skips) skips"
    }
}
