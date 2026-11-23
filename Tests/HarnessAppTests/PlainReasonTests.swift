@testable import HarnessApp
import Testing

struct PlainReasonTests {
    @Test func aFullDiskIsToldAsAFullDisk() {
        let output = "CompileAssetCatalog …\nerror: copy(model.gguf, …/model.gguf): No space left on device (28)"
        #expect(FileChangeAutopilot.plainReason(output)?.contains("ディスクの空き") == true)
        #expect(FileChangeAutopilot.plainReason("CompileAssetCatalog failed") == "アイコンなどの素材をまとめる所で失敗しました。")
    }
}
