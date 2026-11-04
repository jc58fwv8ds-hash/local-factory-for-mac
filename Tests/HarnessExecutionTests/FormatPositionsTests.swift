import Testing
@testable import HarnessExecution

struct FormatPositionsTests {
    @Test func aQuotedLineHeadIsSpelledOutByPosition() {
        let note = FormatPositions.note("行頭の「[数字2桁:数字2桁] 」を外し、「(要確認)」も外す。")
        #expect(note == "Character positions (0-based) of the fixed formats in the request:\n"
                + "- 「[数字2桁:数字2桁] 」 is 8 characters: 0 \"[\", 1-2 digits, 3 \":\", 4-5 digits, 6 \"]\", 7 space.")
    }

    @Test func dateFormatsCountTheirLetters() {
        #expect(FormatPositions.positions("yyyy-MM-dd") == "「yyyy-MM-dd」 is 10 characters: 0-3 digits, 4 \"-\", 5-6 digits, 7 \"-\", 8-9 digits.")
    }

    @Test func theCountStopsAtAWordThatStandsForText() {
        #expect(FormatPositions.positions("[HH:mm] 話者N: 文") == "「[HH:mm] 話者N: 文」 starts with 8 fixed characters: 0 \"[\", 1-2 digits, 3 \":\", 4-5 digits, 6 \"]\", 7 space, then the rest.")
        #expect(FormatPositions.positions("yyyy-MM-dd.json")?.hasSuffix("10 \".\", then the rest.") == true)
    }

    @Test func quotesWithoutDigitsOrWithoutFixedCharactersAreLeftOut() {
        #expect(FormatPositions.note("「話者N:」を付ける。\"数字2桁\" だけ。") == nil)
        #expect(FormatPositions.note("時刻なし") == nil)
        #expect(FormatPositions.note("状態は \"dismissed:1\" と書く") == nil)
    }
}
