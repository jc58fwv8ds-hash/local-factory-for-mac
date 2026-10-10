import Testing
@testable import HarnessApp

struct DogfoodShadowWorkspaceTests {
    @Test func candidateCatalogKeepsPersonalMemoryButSkipsOtherWorkArtifacts() {
        #expect(DogfoodShadowWorkspace.includesPath("work/PersonalMemory"))
        #expect(DogfoodShadowWorkspace.includesPath(
            "work/PersonalMemory/PersonalMemory/PersonalMemoryApp.swift"))
        #expect(!DogfoodShadowWorkspace.includesPath("work/dogfood-ui-v7/Harness Candidate.app"))
        #expect(DogfoodShadowWorkspace.includesPath("Sources/HarnessApp/HarnessApp.swift"))
    }
}
