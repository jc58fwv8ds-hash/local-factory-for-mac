import Foundation
@testable import HarnessCore
import Testing

struct CommandProgressDecodingTests {
    @Test func unicodeSurvivesEveryByteBoundary() {
        let original = "日本語 🍎 e\u{301} downloading 12.5%\r\n"
        let bytes = Array(original.utf8)
        for split in 0...bytes.count {
            var decoder = CommandUTF8Decoder()
            let text = decoder.append(Data(bytes[..<split]))
                + decoder.append(Data(bytes[split...])) + decoder.finish()
            #expect(text == original)
        }
        var decoder = CommandUTF8Decoder()
        var text = ""
        for byte in bytes { text += decoder.append(Data([byte])) }
        text += decoder.finish()
        #expect(text == original)
    }

    @Test func invalidAndIncompleteInputUsesReplacementWithoutLosingASCII() {
        for bytes: [UInt8] in [[0xE3, 0x81], [0xFF, 65], [0xE0, 0x80, 65], [0xF4, 0x90, 0x80, 66]] {
            var decoder = CommandUTF8Decoder()
            var text = ""
            for byte in bytes { text += decoder.append(Data([byte])) }
            text += decoder.finish()
            #expect(text == String(decoding: bytes, as: UTF8.self))
            #expect(decoder.finish().isEmpty)
        }
    }

    @Test func splitProgressAndTerminalControlsAreReassembled() async {
        let stream = ModelAcquisitionProgressStream()
        #expect(await stream.append("\u{1B}[").isEmpty)
        #expect(await stream.append("2Kpull").isEmpty)
        #expect(await stream.append("ing layer 12.").isEmpty)
        #expect(await stream.append("5%").isEmpty)
        let progress = await stream.append("\r\nverifying sha256\n")
        #expect(progress.count == 2)
        #expect(progress.first?.fraction == 0.125)
        #expect(progress.last?.status == "ダウンロード内容を検証しています")
        #expect(await stream.append("writing manifest").isEmpty)
        #expect(await stream.finish()?.status == "モデル情報を保存しています")
        #expect(await stream.finish() == nil)
    }

    @Test func oversizedRecordIsDiscardedUntilNextDelimiter() async {
        let stream = ModelAcquisitionProgressStream()
        #expect(await stream.append(String(repeating: "x", count: 20_000)).isEmpty)
        #expect(await stream.append("downloading 99%\n").isEmpty)
        let progress = await stream.append("downloading 25%\r")
        #expect(progress.count == 1)
        #expect(progress.first?.fraction == 0.25)
    }
}
