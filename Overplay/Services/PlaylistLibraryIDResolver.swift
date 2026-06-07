import Foundation

enum PlaylistLibraryIDResolver {
    struct Candidate: Equatable, Sendable {
        var id: String
        var name: String
    }

    static func resolvedMusicPlaylistID(
        storedID: String,
        name: String?,
        libraryPlaylists: [Candidate]
    ) -> String? {
        if libraryPlaylists.contains(where: { $0.id == storedID }) {
            return storedID
        }

        guard let name else {
            return nil
        }

        let nameMatches = libraryPlaylists.filter {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }

        switch nameMatches.count {
        case 1:
            return nameMatches[0].id
        case 0:
            return nil
        default:
            let preferredMatches = nameMatches.filter {
                $0.name.localizedCaseInsensitiveCompare("Overplay") == .orderedSame
            }
            return preferredMatches.count == 1 ? preferredMatches[0].id : nil
        }
    }
}
