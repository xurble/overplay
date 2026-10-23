import Foundation

/// A song's title and primary artist reduced to what makes two listings the
/// same song: case, accents, punctuation, featured artists and labels that
/// do not change the recording ("Remastered 2011", "Single Version") go.
/// Labels that do ("Live", "Remix", "Acoustic", "Edit") stay, so those never
/// match the original by name.
enum DuplicateNameKey {
    static func make(title: String, artist: String) -> String? {
        let title = normalizedTitle(title)
        let artist = primaryArtist(artist)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return "name:\(title)|\(artist)"
    }

    /// Bracketed or dashed labels that say nothing about the recording.
    private static let neutralLabel = try! NSRegularExpression(
        pattern: #"\s*(?:[\(\[]\s*|\s-\s+)(?:\d{4}\s+)?(?:remaster(?:ed)?|digital(?:ly)? remaster(?:ed)?|single version|album version|lp version|original version|mono|stereo|deluxe(?: edition| version)?|bonus track|explicit|clean|remaster(?:ed)? version)(?:\s+\d{4})?(?:\s*[\)\]])?"#,
        options: [.caseInsensitive]
    )
    /// "(feat. X)", "[with X]": whole words only, so "Left Behind" keeps its
    /// "ft". "with" counts only in brackets, so "Stay With Me" is untouched.
    private static let bracketedFeaturing = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*(?:feat|ft|featuring|with)\b\.?\s+[^\)\]]*[\)\]]"#,
        options: [.caseInsensitive]
    )
    /// "Song feat. X" to the end of the title; without brackets only "feat.",
    /// "ft." or "featuring" count, so "A Feat of Clay" stays whole.
    private static let trailingFeaturing = try! NSRegularExpression(
        pattern: #"\s+(?:feat\.|ft\.|featuring\b)\s*.*$"#,
        options: [.caseInsensitive]
    )

    static func normalizedTitle(_ title: String) -> String {
        var value = title
        for pattern in [bracketedFeaturing, trailingFeaturing, neutralLabel] {
            value = pattern.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        }
        return simplified(value)
    }

    /// The first named artist: "Daft Punk feat. Pharrell" and "Daft Punk &
    /// Pharrell" both match "Daft Punk".
    static func primaryArtist(_ artist: String) -> String {
        var value = simplified(artist)
        for separator in [" feat ", " ft ", " featuring ", " with ", " and ", " x ", ","] {
            if let range = value.range(of: separator) { value = String(value[..<range.lowerBound]) }
        }
        if value.hasPrefix("the ") { value.removeFirst(4) }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func simplified(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
