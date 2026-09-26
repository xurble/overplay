import Foundation

/// Display-only alternatives, ordered from complete metadata to the shortest label.
enum TrackTextVariants {
    static func candidates(for text: String) -> [String] {
        candidates(for: [text], separator: "")
    }

    static func candidates(for components: [String], separator: String) -> [String] {
        let withoutBrackets = components.map { removingTrailingGroups(from: $0, opening: "[", closing: "]") }
        let withoutParentheses = withoutBrackets.map { removingTrailingGroups(from: $0, opening: "(", closing: ")") }
        return [components, withoutBrackets, withoutParentheses]
            .map { $0.joined(separator: separator) }
            .reduce(into: []) { result, candidate in
                if result.last != candidate { result.append(candidate) }
            }
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
