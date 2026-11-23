@testable import HarnessCore
import Testing


struct SamplerWithoutPickTests {
    @Test func aChainWithNoPickingSamplerIsFound() {
        let chain = "let chain = llama_sampler_chain_init(p)\nllama_sampler_chain_add(chain, llama_sampler_init_temp(0.2))\nllama_sampler_chain_add(chain, llama_sampler_init_top_k(40))"
        #expect(NotWorkingHints.samplerWithoutPick([("App/PlamoTranslator.swift", chain)]).first?.contains("llama_sampler_init_dist") == true)
        #expect(NotWorkingHints.samplerWithoutPick([("App/P.swift", chain + "\nllama_sampler_chain_add(chain, llama_sampler_init_dist(1))")]).isEmpty)
    }
}
