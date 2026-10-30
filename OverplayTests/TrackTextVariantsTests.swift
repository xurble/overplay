import Testing
@testable import Overplay

struct TrackTextVariantsTests {
    @Test func suffixesAreRemovedInPriorityOrder() {
        #expect(TrackTextVariants.candidates(for: "Song (Live) [Deluxe]") == [
            "Song (Live) [Deluxe]", "Song (Live)", "Song"
        ])
    }

    @Test func remasterNotesNeverShow() {
        #expect(TrackTextVariants.candidates(for: "Song (Live) [Remastered]") == ["Song (Live)", "Song"])
        #expect(TrackTextVariants.removingRemasterNotes(from: "Song (2025 Remaster)") == "Song")
        #expect(TrackTextVariants.removingRemasterNotes(from: "Song [Remastered 2009]") == "Song")
        #expect(TrackTextVariants.removingRemasterNotes(from: "Song (2011 Remastered Version) (Live)") == "Song (Live)")
        #expect(TrackTextVariants.removingRemasterNotes(from: "Song - 2015 Remaster") == "Song")
        #expect(TrackTextVariants.removingRemasterNotes(from: "Song - Remastered") == "Song")
        // Only a note goes: a name that is the note, or has none, is kept.
        #expect(TrackTextVariants.removingRemasterNotes(from: "(Remastered)") == "(Remastered)")
        #expect(TrackTextVariants.removingRemasterNotes(from: "Remaster Me ") == "Remaster Me ")
    }

    @Test(arguments: ["(What's So Funny) About Love", "Song [Live] Again", "(Intro)", "[Intro]", "Song (Unclosed"])
    func preservesNamesAndNonTrailingGroups(text: String) {
        #expect(TrackTextVariants.candidates(for: text) == [text])
    }

    @Test func handlesNestedAndRepeatedSuffixes() {
        #expect(TrackTextVariants.candidates(for: "Song (Live (London)) [Deluxe] [2026]") == [
            "Song (Live (London)) [Deluxe] [2026]", "Song (Live (London))", "Song"
        ])
        #expect(TrackTextVariants.candidates(for: "(Intro) Song (Live) (Acoustic)") == [
            "(Intro) Song (Live) (Acoustic)", "(Intro) Song"
        ])
    }

    @Test func shortensArtistAndAlbumIndependently() {
        #expect(TrackTextVariants.candidates(
            for: ["Artist (Orchestra) [UK]", "Album (Deluxe) [Expanded]"], separator: " - "
        ) == [
            "Artist (Orchestra) [UK] - Album (Deluxe) [Expanded]",
            "Artist (Orchestra) - Album (Deluxe)", "Artist - Album"
        ])
    }

    @Test func preservesUnicodeAndHandlesEmptyText() {
        #expect(TrackTextVariants.candidates(for: "夜 🌙 [Live] ") == ["夜 🌙 [Live] ", "夜 🌙"])
        #expect(TrackTextVariants.candidates(for: "") == [""])
    }
}
