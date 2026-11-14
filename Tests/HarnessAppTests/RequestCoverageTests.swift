import HarnessCore
import Testing

struct RequestCoverageTests {
    @Test func theWritersFixedPromptReplacesOneThatLeftSomethingOut() {
        let prompt = "A man stands in a plain white studio."
        let ask = RequestCoverage.request(instruction: "木造の日本家屋の床の間の前で正座させて", prompt: prompt, isVideo: false)
        #expect(ask.contains("木造の日本家屋の床の間の前で正座させて") && ask.contains(prompt) && ask.contains("FIXED:"))
        #expect(RequestCoverage.apply("OK", to: prompt) == prompt)
        #expect(RequestCoverage.apply("FIXED: A man kneels in seiza before the tokonoma alcove of a wooden Japanese house.", to: prompt)
            == "A man kneels in seiza before the tokonoma alcove of a wooden Japanese house.")
        // A cut-off answer does not replace the prompt.
        #expect(RequestCoverage.apply("FIXED: A", to: prompt) == prompt)
    }

    @Test func aMovedPlaceLeavesNoStudioBehind() {
        let kept = "A full-body shot of a woman with straight black hair, standing in a plain white studio setting. She smiles. The location is Hong Kong."
        let fixed = RequestCoverage.droppingOldBackdrop(kept, instruction: "場所を香港にして")
        #expect(!fixed.contains("studio") && fixed.contains("Hong Kong") && fixed.contains("standing. She smiles."))
        #expect(RequestCoverage.droppingOldBackdrop("A cat against a blue background.", instruction: "猫を大きくして") == "A cat against a blue background.")
        #expect(!RequestCoverage.request(instruction: "場所を香港にして", prompt: kept, isVideo: false).isEmpty)
    }

    @Test func aPlacePhraseBecomesTheSceneOfTheFirstSentence() {
        let prompt = "A full-body shot of a woman with straight black hair, standing. She smiles. The location is Hong Kong."
        let placed = RequestCoverage.placing("in a narrow Hong Kong street lined with neon signs, people passing by.", in: prompt, instruction: "場所を香港にして")
        #expect(placed == "A full-body shot of a woman with straight black hair, standing, in a narrow Hong Kong street lined with neon signs, people passing by. She smiles.")
        #expect(RequestCoverage.placing("NONE", in: prompt, instruction: "笑顔にして") == prompt)
        #expect(RequestCoverage.placeQuestion(instruction: "マンションの一室で", previousPrompt: nil).contains("マンションの一室で"))
    }
}
