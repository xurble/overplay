import Testing
@testable import Overplay

struct TrackTextVariantsTests {
    @Test func suffixesAreRemovedInPriorityOrder() {
        #expect(TrackTextVariants.candidates(for: "Song (Live) [Remastered]") == [
            "Song (Live) [Remastered]", "Song (Live)", "Song"
        ])
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
            for: ["Artist (Orchestra) [UK]", "Album (Deluxe) [Remastered]"], separator: " - "
        ) == [
            "Artist (Orchestra) [UK] - Album (Deluxe) [Remastered]",
            "Artist (Orchestra) - Album (Deluxe)", "Artist - Album"
        ])
    }

    @Test func preservesUnicodeAndHandlesEmptyText() {
        #expect(TrackTextVariants.candidates(for: "夜 🌙 [Live] ") == ["夜 🌙 [Live] ", "夜 🌙"])
        #expect(TrackTextVariants.candidates(for: "") == [""])
    }
}
