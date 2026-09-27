import Foundation

nonisolated enum PortableArtworkReference {
    /// Apple Music web artwork is a template, not a ready-to-fetch URL.
    /// Download one 512px master and let the cache produce both local sizes.
    static func requestURL(_ template: String) -> URL? {
        guard let template = validated(template) else { return nil }
        let value = template.replacingOccurrences(of: "{w}", with: "512")
            .replacingOccurrences(of: "{h}", with: "512")
        guard !value.contains("{"), !value.contains("}") else { return nil }
        return URL(string: value)
    }

    static func validated(_ value: String?) -> String? {
        guard let value, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return value
    }
}
