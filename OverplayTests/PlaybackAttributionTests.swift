import Foundation
import Testing
@testable import Overplay

/// `PLAY-012`: which intent member a player-reported item is counted against.
/// Pure tables over `PlaybackAttribution`; nil means "not attributed".
@MainActor
struct PlaybackAttributionTests {
    nonisolated private static func member(
        _ localID: String, ids: [String] = [], title: String = "Song", artist: String = "Artist",
        duration: Double? = 180
    ) -> PlaybackIntent.Member {
        PlaybackIntent.Member(localTrackID: localID, playlistItemID: nil, musicItemIDs: ids, title: title,
                              artistName: artist, albumTitle: nil, artworkURLTemplate: nil, durationSeconds: duration)
    }

    nonisolated private static func item(
        ids: Set<String> = [], title: String = "Song", artist: String = "Artist", duration: Double? = 180
    ) -> PlayerItemSnapshot {
        PlayerItemSnapshot(id: ids.first ?? "reported", identifiers: ids, title: title, artistName: artist,
                           albumTitle: nil, artworkURLTemplate: nil, durationSeconds: duration)
    }

    private static func attribution(_ members: [PlaybackIntent.Member]) -> PlaybackAttribution {
        PlaybackAttribution(intent: PlaybackIntent(id: UUID(), createdAt: .now, musicPlaylistID: "playlist",
                                                   scope: .active, members: members))
    }

    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let members: [PlaybackIntent.Member]
        let item: PlayerItemSnapshot
        var cached: String? = nil
        /// The member's local ID, or nil for "not attributed".
        let expected: String?
        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(name: "one identifier match wins over different metadata",
             members: [member("a", ids: ["i.a"], title: "Alpha"), member("b", ids: ["i.b"], title: "Beta")],
             item: item(ids: ["i.a"], title: "Something Else", duration: 999), expected: "a"),
        Case(name: "identifiers matching two members are ambiguous",
             members: [member("a", ids: ["i.a"], title: "Alpha"), member("b", ids: ["i.b"], title: "Beta")],
             item: item(ids: ["i.a", "i.b"], title: "Alpha"), expected: nil),
        Case(name: "one shared identifier on two members is ambiguous",
             members: [member("a", ids: ["cat-1"], title: "Alpha"), member("b", ids: ["cat-1"], title: "Beta")],
             item: item(ids: ["cat-1"], title: "Alpha"), expected: nil),
        Case(name: "an ambiguous identifier match does not fall back to metadata",
             members: [member("a", ids: ["i.a"], title: "Alpha"), member("b", ids: ["i.b"], title: "Beta")],
             item: item(ids: ["i.a", "i.b"], title: "Beta"), expected: nil),
        Case(name: "unknown identifiers fall back to a unique metadata match",
             members: [member("a", ids: ["i.a"], title: "Alpha"), member("b", ids: ["i.b"], title: "Beta")],
             item: item(ids: ["other-domain"], title: "Beta"), expected: "b"),
        Case(name: "two members with the same normalised title and artist are ambiguous",
             members: [member("a", ids: ["i.a"], title: "Café  Song", artist: "The Band"),
                       member("b", ids: ["i.b"], title: "cafe song", artist: "THE BAND")],
             item: item(title: "Cafe Song", artist: "The Band"), expected: nil),
        Case(name: "a duration more than 2 s apart vetoes a metadata match",
             members: [member("a", title: "Alpha", duration: 180)],
             item: item(title: "Alpha", duration: 182.5), expected: nil),
        Case(name: "a duration exactly 2 s apart still agrees",
             members: [member("a", title: "Alpha", duration: 180)],
             item: item(title: "Alpha", duration: 182), expected: "a"),
        Case(name: "a missing item duration does not veto",
             members: [member("a", title: "Alpha", duration: 180)],
             item: item(title: "Alpha", duration: nil), expected: "a"),
        Case(name: "a non-finite member duration does not veto",
             members: [member("a", title: "Alpha", duration: .nan)],
             item: item(title: "Alpha", duration: 10), expected: "a"),
        Case(name: "case, diacritics, width and whitespace fold in a metadata match",
             members: [member("a", title: "  Déjà   Vu\t", artist: "Ｂｅｙｏｎｃé")],
             item: item(title: "deja vu", artist: "BEYONCE"), expected: "a"),
        Case(name: "an empty item title is never matched by metadata",
             members: [member("a", title: "", artist: "Artist")],
             item: item(title: "", artist: "Artist"), expected: nil),
        Case(name: "a whitespace-only item artist is never matched by metadata",
             members: [member("a", title: "Alpha", artist: "Artist")],
             item: item(title: "Alpha", artist: "  "), expected: nil),
        Case(name: "a different artist is no metadata match",
             members: [member("a", title: "Alpha", artist: "One")],
             item: item(title: "Alpha", artist: "Two"), expected: nil),
        Case(name: "a cached attribution corroborated by metadata alone is kept",
             members: [member("a", ids: ["i.a"], title: "Alpha"), member("b", ids: ["i.b"], title: "Alpha")],
             item: item(ids: ["re-issued"], title: "Alpha"), cached: "a", expected: "a"),
        Case(name: "a cached attribution corroborated by identifier is kept over an ambiguous match",
             members: [member("a", ids: ["i.a"], title: "Alpha"), member("b", ids: ["i.b"], title: "Beta")],
             item: item(ids: ["i.a", "i.b"], title: "Other"), cached: "a", expected: "a"),
        Case(name: "a cached attribution that no longer corroborates is re-attributed",
             members: [member("a", ids: ["i.a"], title: "Alpha"), member("b", ids: ["i.b"], title: "Beta")],
             item: item(ids: ["i.b"], title: "Beta"), cached: "a", expected: "b"),
        Case(name: "a cached attribution vetoed by duration is dropped",
             members: [member("a", ids: ["i.a"], title: "Alpha", duration: 180),
                       member("b", ids: ["i.b"], title: "Gamma", duration: 240)],
             item: item(ids: ["new"], title: "Alpha", duration: 240), cached: "a", expected: nil),
        Case(name: "a cached attribution that no longer corroborates and matches nothing is nil",
             members: [member("a", ids: ["i.a"], title: "Alpha")],
             item: item(ids: ["new"], title: "Other"), cached: "a", expected: nil),
        Case(name: "a cached ID outside the intent is ignored",
             members: [member("a", ids: ["i.a"], title: "Alpha")],
             item: item(ids: ["i.a"], title: "Alpha"), cached: "gone", expected: "a"),
        // Pinned, not endorsed: metadata corroboration of the cached member
        // runs before the identifiers are checked. Two copies of one song
        // (same title, artist and length) keep the cached copy even when the
        // item's identifier names the other copy uniquely.
        Case(name: "pinned: metadata corroboration of the cache beats a unique identifier match",
             members: [member("a", ids: ["i.a"], title: "Alpha"), member("b", ids: ["i.b"], title: "Alpha")],
             item: item(ids: ["i.b"], title: "Alpha"), cached: "a", expected: "a"),
        // Pinned, not endorsed: `corroborates` compares two optional keys,
        // so an item with no usable metadata corroborates a cached member
        // that has none either (nil == nil), with no identifier in common.
        Case(name: "pinned: no usable metadata on either side corroborates the cache",
             members: [member("a", ids: ["i.a"], title: "Alpha", artist: "")],
             item: item(ids: ["unrelated"], title: "", artist: "", duration: nil), cached: "a", expected: "a"),
    ]

    @Test(arguments: cases)
    func attributes(_ testCase: Case) {
        let attribution = Self.attribution(testCase.members)
        let member = attribution.member(for: testCase.item, cachedLocalTrackID: testCase.cached)
        #expect(member?.localTrackID == testCase.expected)
    }

    @Test(arguments: [
        ("Song", "Artist", "song\u{1F}artist"),
        ("  Two   Words ", "Artist", "two words\u{1F}artist"),
        ("Tab\tand\nnewline", "Artist", "tab and newline\u{1F}artist"),
        ("Non\u{00A0}breaking", "Artist", "non breaking\u{1F}artist"),
        ("Café", "Sigur Rós", "cafe\u{1F}sigur ros"),
        ("ＦＵＬＬ　ＷＩＤＴＨ", "Artist", "full width\u{1F}artist"),
        ("ÅNGSTRÖM", "Artist", "angstrom\u{1F}artist"),
    ])
    func metadataKeyFolds(title: String, artist: String, expected: String) {
        #expect(PlaybackAttribution.metadataKey(title: title, artist: artist) == expected)
    }

    @Test(arguments: [("", "Artist"), ("Song", ""), ("   ", "Artist"), ("Song", "\t\n"), ("", "")])
    func metadataKeyNeedsTitleAndArtist(title: String, artist: String) {
        #expect(PlaybackAttribution.metadataKey(title: title, artist: artist) == nil)
    }

    @Test func durationsAgreeWithinTwoSecondsEitherWay() {
        #expect(PlaybackAttribution.durationsAgree(180, 178))
        #expect(PlaybackAttribution.durationsAgree(178, 180))
        #expect(!PlaybackAttribution.durationsAgree(180, 177.9))
        #expect(!PlaybackAttribution.durationsAgree(177.9, 180))
        #expect(PlaybackAttribution.durationsAgree(nil, 10))
        #expect(PlaybackAttribution.durationsAgree(10, nil))
        #expect(PlaybackAttribution.durationsAgree(.infinity, 10))
    }
}
