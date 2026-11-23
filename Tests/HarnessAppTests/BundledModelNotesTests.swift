import Foundation
import Testing
@testable import HarnessCore

struct BundledModelNotesTests {
    static func gguf(template: String, bos: (UInt32, Bool)? = nil) -> Data {
        var d = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func str(_ s: String) { u64(UInt64(s.utf8.count)); d.append(contentsOf: Data(s.utf8)) }
        u32(3); u64(0); u64(bos == nil ? 3 : 5)
        str("general.name"); u32(8); str("tiny")
        str("tokenizer.ggml.tokens"); u32(9); u32(8); u64(2); str("<s>"); str("<|m:bos|>")
        if let bos { str("tokenizer.ggml.bos_token_id"); u32(4); u32(bos.0); str("tokenizer.ggml.add_bos_token"); u32(7); d.append(bos.1 ? 1 : 0) }
        str("tokenizer.chat_template"); u32(8); str(template)
        return d
    }

    @Test func theTemplateCommentsOfABundledModelGoWithRequestsToCodeThatWritesItsPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/Models"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.gguf(template: "{# a chat client's [settings] block #}\n{{- '<|plamo:tag|>output' -}}\n{{- '<|plamo:key|>form<|plamo:val|>' + form -}}\n{{- raise_exception('<|bad|>') -}}")
            .write(to: root.appendingPathComponent("App/Models/m.gguf"))
        #expect(BundledModelNotes.chatTemplate(of: root.appendingPathComponent("App/Models/m.gguf"))?.contains("[settings]") == true)
        try "let p = \"x\"".write(to: root.appendingPathComponent("App/T.swift"), atomically: true, encoding: .utf8)
        #expect(BundledModelNotes.notes(rootURL: root) == nil)   // no hand-written prompt, nothing to say
        try "let p = \"<|plamo:tag|>dataset\"".write(to: root.appendingPathComponent("App/T.swift"), atomically: true, encoding: .utf8)
        let notes = try #require(BundledModelNotes.notes(rootURL: root))
        #expect(notes.contains("'<|plamo:tag|>output'\n'<|plamo:key|>form<|plamo:val|>' + form"))
        #expect(!notes.contains("[settings]") && !notes.contains("<|bad|>"))   // only the lines that write the format
    }

    @Test func aLoopOverEarlierTurnsIsShownAsALoopNotAsASecondInput() {
        let template = """
        {%- for message in translation_messages[:-1] -%}
            {{- '<|plamo:tag|>input' -}}
            {{- '<|plamo:msg|>' + message['content'] -}}
        {%- endfor -%}
        {%- if glossary is defined and glossary -%}
            {%- if x -%}
            {%- endif -%}
            {{- '<|plamo:tag|>glossary' -}}
        {%- endif -%}
        {{- '<|plamo:tag|>input' -}}
        {{- '<|plamo:msg|>' + translation_messages[-1]['content'] -}}
        """
        let lines = BundledModelNotes.formatLines(template)
        #expect(lines.first == "(くり返し: message in translation_messages[:-1])")
        #expect(lines.contains("(くり返しここまで)"))
        #expect(lines.contains("(glossary is defined and glossary のときだけ)"))
        #expect(!lines.contains { $0.contains("x のときだけ") })   // a block that writes nothing is left out
        #expect(lines.last == "'<|plamo:msg|>' + translation_messages[-1]['content']")
    }

    @Test func theRealBeginningTokenIsNamedAndWhetherItIsAddedForYou() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/Models"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.gguf(template: "{{- bos_token + '<|m:tag|>dataset' -}}", bos: (1, true)).write(to: root.appendingPathComponent("App/Models/m.gguf"))
        #expect(BundledModelNotes.beginningToken(of: root.appendingPathComponent("App/Models/m.gguf"))! == ("<|m:bos|>", true))
        try "let p = \"<|m:tag|>dataset\"".write(to: root.appendingPathComponent("App/T.swift"), atomically: true, encoding: .utf8)
        let notes = try #require(BundledModelNotes.notes(rootURL: root))
        #expect(notes.contains("bos_token はこのモデルでは「<|m:bos|>」です。"))
        #expect(notes.contains("文字列には書かないでください"))
    }

    @Test func aMarkTheModelsFormatDoesNotUseIsFoundInTheAppsPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App/Models"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.gguf(template: "{{- bos_token + '<|m:tag|>dataset' -}}", bos: (1, true)).write(to: root.appendingPathComponent("App/Models/m.gguf"))
        try "let p = \"<s>\" + \"<|m:tag|>dataset\"\n// \"<s>\" in a comment\n".write(to: root.appendingPathComponent("App/T.swift"), atomically: true, encoding: .utf8)
        let found = BundledPromptCheck.diagnostics(rootURL: root)
        #expect(found.count == 1)
        #expect(found.first?.line == 1)
        #expect(found.first?.message.contains("「<s>」") == true)
        #expect(found.first?.message.contains("「<|m:bos|>」で、文字列を言葉に分けるときに自動で付きます") == true)
        try "let p = \"<|m:tag|>dataset\"".write(to: root.appendingPathComponent("App/T.swift"), atomically: true, encoding: .utf8)
        #expect(BundledPromptCheck.diagnostics(rootURL: root).isEmpty)
    }
}
