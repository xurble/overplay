import Foundation
import Testing
@testable import Overplay

@Suite("Sequence dictionary helpers")
struct SequenceDictionaryTests {
    @Test("first value dictionary keeps the first element for duplicate keys")
    func firstValueDictionaryKeepsFirstDuplicateKey() {
        let rows = [
            Row(key: "track-1", value: "First"),
            Row(key: "track-2", value: "Second"),
            Row(key: "track-1", value: "Duplicate")
        ]

        let dictionary = rows.firstValueDictionary(keyedBy: \.key, value: \.value)

        #expect(dictionary["track-1"] == "First")
        #expect(dictionary["track-2"] == "Second")
    }

    private struct Row {
        var key: String
        var value: String
    }
}
