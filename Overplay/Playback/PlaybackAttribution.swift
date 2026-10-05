import Foundation

/// Attributes a player-reported entry to a playback-intent member (`PLAY-012`).
///
/// Pure. Failure returns nil and never clears anything: an unattributed entry
/// is still displayed, it just carries no Overplay data and is not counted.
struct PlaybackAttribution {
    private let membersByLocalID: [String: PlaybackIntent.Member]
    private let localIDsByMusicID: [String: Set<String>]
    private let localIDsByMetadata: [String: Set<String>]

    init(intent: PlaybackIntent) {
        var byLocalID: [String: PlaybackIntent.Member] = [:]
        var byMusicID: [String: Set<String>] = [:]
        var byMetadata: [String: Set<String>] = [:]
        for member in intent.members {
            byLocalID[member.localTrackID] = member
            for id in member.musicItemIDs { byMusicID[id, default: []].insert(member.localTrackID) }
            if let key = Self.metadataKey(title: member.title, artist: member.artistName) {
                byMetadata[key, default: []].insert(member.localTrackID)
            }
        }
        membersByLocalID = byLocalID
        localIDsByMusicID = byMusicID
        localIDsByMetadata = byMetadata
    }

    /// `cachedLocalTrackID` is an earlier attribution of the same entry ID in
    /// this intent. It is trusted only while the item still corroborates it.
    func member(for item: PlayerItemSnapshot, cachedLocalTrackID: String? = nil) -> PlaybackIntent.Member? {
        if let cachedLocalTrackID, let cached = membersByLocalID[cachedLocalTrackID],
           corroborates(cached, item) {
            return cached
        }

        let idMatches = item.identifiers.reduce(into: Set<String>()) { result, id in
            result.formUnion(localIDsByMusicID[id] ?? [])
        }
        if idMatches.count == 1, let localID = idMatches.first {
            return membersByLocalID[localID]
        }
        if idMatches.count > 1 { return nil }

        guard let key = Self.metadataKey(title: item.title, artist: item.artistName),
              let candidates = localIDsByMetadata[key], candidates.count == 1,
              let member = candidates.first.flatMap({ membersByLocalID[$0] }),
              Self.durationsAgree(member.durationSeconds, item.durationSeconds) else {
            return nil
        }
        return member
    }

    func member(localTrackID: String?) -> PlaybackIntent.Member? {
        localTrackID.flatMap { membersByLocalID[$0] }
    }

    private func corroborates(_ member: PlaybackIntent.Member, _ item: PlayerItemSnapshot) -> Bool {
        if !item.identifiers.isDisjoint(with: member.musicItemIDs) { return true }
        return Self.metadataKey(title: item.title, artist: item.artistName)
            == Self.metadataKey(title: member.title, artist: member.artistName)
            && Self.durationsAgree(member.durationSeconds, item.durationSeconds)
    }

    /// Case-, diacritic- and whitespace-insensitive title and artist.
    static func metadataKey(title: String, artist: String) -> String? {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let title = normalized(title), artist = normalized(artist)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return "\(title)\u{1F}\(artist)"
    }

    static func durationsAgree(_ left: Double?, _ right: Double?) -> Bool {
        guard let left, let right, left.isFinite, right.isFinite else { return true }
        return abs(left - right) <= 2
    }
}
