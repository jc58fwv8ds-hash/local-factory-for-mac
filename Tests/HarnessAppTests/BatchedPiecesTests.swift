import Testing
@testable import HarnessCore

struct BatchedPiecesTests {
    @Test func findsALongPieceWorkedThroughBeforeAnythingShows() {
        let log = ["[PlamoTranslator] セグメント 1/9 を処理中: For the FBI....", "[PlamoTranslator] 翻訳完了: FBIのために。...",
                   "[PlamoTranslator] セグメント 4/9 を処理中: I mean,...", "[TranslationController] Stop requested"]
        let hints = NotWorkingHints.batchedPieces(log)
        #expect(hints.first?.contains("9 個") == true)
        #expect(hints.first?.contains("途中で止められています") == true)
        #expect(NotWorkingHints.batchedPieces(["セグメント 1/2 を処理中"]).isEmpty)
    }
}
