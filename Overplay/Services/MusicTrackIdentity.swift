import Foundation
@preconcurrency import MusicKit

/// Splits MusicKit item identifiers into their catalog and library domains.
///
/// Apple Music exposes two ID domains for the same song: catalog IDs
/// (numeric) and library IDs (prefixed with "i."). Overplay must keep them
/// distinct, never mirrored, so a song fetched from different sources
/// (library playlist sync, catalog search, queue entries) collapses to one
/// local track identity.
enum MusicTrackIdentity {
    struct IDs: Equatable, Sendable {
        var catalogID: String?
        var libraryID: String?

        init(catalogID: String? = nil, libraryID: String? = nil) {
            self.catalogID = catalogID
            self.libraryID = libraryID
        }
    }

    static func isLibraryID(_ rawID: String) -> Bool {
        rawID.hasPrefix("i.")
    }

    static func ids(fromRawID rawID: String) -> IDs {
        isLibraryID(rawID) ? IDs(libraryID: rawID) : IDs(catalogID: rawID)
    }

    static func ids(for track: Track) -> IDs {
        ids(fromRawID: track.id.rawValue, playParameters: track.playParameters)
    }

    static func ids(fromRawID rawID: String, playParameters: PlayParameters?) -> IDs {
        ids(
            fromRawID: rawID,
            playParametersData: playParameters.flatMap { try? JSONEncoder().encode($0) }
        )
    }

    /// Play parameters are the only place MusicKit exposes a library track's
    /// catalog correspondence. Their JSON shape is not API-stable, so decoding
    /// is best-effort enrichment: any failure falls back to classifying the
    /// raw ID alone.
    static func ids(fromRawID rawID: String, playParametersData: Data?) -> IDs {
        var ids = ids(fromRawID: rawID)
        guard let playParametersData,
              let decoded = try? JSONDecoder().decode(DecodedPlayParameters.self, from: playParametersData) else {
            return ids
        }

        if ids.catalogID == nil {
            ids.catalogID = decoded.catalogIDValue
        }
        if ids.libraryID == nil {
            ids.libraryID = decoded.libraryIDValue
        }
        return ids
    }
}

extension TrackSnapshot {
    /// Identity used for local track record matching. Falls back to
    /// classifying the raw snapshot ID when neither domain ID was captured.
    var resolvedIdentity: MusicTrackIdentity.IDs {
        if catalogID != nil || libraryID != nil {
            return MusicTrackIdentity.IDs(catalogID: catalogID, libraryID: libraryID)
        }
        return MusicTrackIdentity.ids(fromRawID: id)
    }
}

private struct DecodedPlayParameters: Decodable {
    var id: FlexibleMusicID?
    var catalogId: FlexibleMusicID?
    var isLibrary: Bool?

    var catalogIDValue: String? {
        if let catalogId, !MusicTrackIdentity.isLibraryID(catalogId.value) {
            return catalogId.value
        }
        guard isLibrary != true,
              let id,
              !MusicTrackIdentity.isLibraryID(id.value) else {
            return nil
        }
        return id.value
    }

    var libraryIDValue: String? {
        guard let id,
              isLibrary == true || MusicTrackIdentity.isLibraryID(id.value) else {
            return nil
        }
        return id.value
    }
}

/// Catalog IDs appear as JSON numbers in play parameters; library IDs as
/// strings. Accept either representation.
private struct FlexibleMusicID: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = String(try container.decode(Int64.self))
        }
    }
}
