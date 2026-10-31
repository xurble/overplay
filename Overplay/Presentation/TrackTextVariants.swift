import Foundation

/// Display-only alternatives, ordered from complete metadata to the shortest label.
enum TrackTextVariants {
    static func candidates(for text: String) -> [String] {
        candidates(for: [text], separator: "")
    }

    static func candidates(for components: [String], separator: String) -> [String] {
        // Remaster notes never show, even when there is room (owner request,
        // 2026-10-30).
        let components = components.map { removingRemasterNotes(from: $0) }
        let withoutBrackets = components.map { removingTrailingGroups(from: $0, opening: "[", closing: "]") }
        let withoutParentheses = withoutBrackets.map { removingTrailingGroups(from: $0, opening: "(", closing: ")") }
        return [components, withoutBrackets, withoutParentheses]
            .map { $0.joined(separator: separator) }
            .reduce(into: []) { result, candidate in
                if result.last != candidate { result.append(candidate) }
            }
    }

    /// "(2025 Remaster)", "[Remastered 2009]", "(2011 Remastered Version)",
    /// " - 2015 Remaster", " - Remastered": any group or dash suffix naming a
    /// remaster, with or without a year.
    static func removingRemasterNotes(from text: String) -> String {
        let removed = text
            .replacing(/\s*[\(\[][^\(\)\[\]]*\bremaster(?:ed)?\b[^\(\)\[\]]*[\)\]]/.ignoresCase(), with: "")
            .replacing(/\s+[-–—]\s+[^-–—]*\bremaster(?:ed)?\b.*$/.ignoresCase(), with: "")
        // Text without a note is left exactly as it was.
        guard removed != text else { return text }
        let cleaned = removed.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name that is nothing but the note stays as it was.
        return cleaned.isEmpty ? text : cleaned
    }

    private static func removingTrailingGroups(from text: String, opening: Character, closing: Character) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.last == closing {
            var depth = 0
            var groupStart: String.Index?
            for index in result.indices.reversed() {
                if result[index] == closing { depth += 1 }
                if result[index] == opening {
                    depth -= 1
                    if depth == 0 {
                        groupStart = index
                        break
                    }
                }
            }
            guard let groupStart else { break }
            let prefix = result[..<groupStart].trimmingCharacters(in: .whitespacesAndNewlines)
            // A name entirely in parentheses/brackets is not a suffix.
            guard !prefix.isEmpty else { break }
            result = prefix
        }
        return result
    }
}
