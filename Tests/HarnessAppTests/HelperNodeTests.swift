import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// The light-job helper Mac (2026-10-18).
struct HelperNodeTests {
    @Test func theThunderboltAddressIsReadFromTheARPTable() {
        let arp = """
        example-air.local (169.254.16.232) at aa:bb:cc:dd:ee:ff on bridge0 [ethernet]
        mdns.mcast.net (224.0.0.251) at 1:0:5e:0:0:fb on bridge0 ifscope permanent [ethernet]
        """
        #expect(HelperNode.parseARP(arp, hostName: "Example-Air") == "169.254.16.232")
        #expect(HelperNode.parseARP(arp, hostName: "Example-Air.local") == "169.254.16.232")
        #expect(HelperNode.parseARP(arp, hostName: "other-mac") == nil)
        #expect(HelperNode.parseARP("air.local (192.168.0.253) at 1:2 on en0", hostName: "air") == nil)   // not Thunderbolt
        let dnssd = """
        18:38:37.031  Add  40000003      15  Example-Air.local.         169.254.16.232                               4500
        18:38:37.031  Add  40000003      27  Example-Air.local.         169.254.113.78                               4500
        18:38:37.031  Add  40000002      14  Example-Air.local.         192.168.0.253                                4500
        """
        #expect(HelperNode.parseLinkLocal(dnssd) == ["169.254.16.232", "169.254.113.78"])
    }

    @Test func aDisabledHelperIsNeverUsed() async {
        #expect(await HelperNode().ensureReady(.init(enabled: false, hostName: "Example-Air")) == false)
        #expect(await HelperNode().ensureReady(.init(enabled: true, hostName: "")) == false)
    }

    /// The real helper Mac: start its model, ask a light job through the tunnel, stop it. HARNESS_HELPER_LIVE=<host name>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HARNESS_HELPER_LIVE"] != nil))
    func theRealHelperAnswersALightJob() async throws {
        let host = ProcessInfo.processInfo.environment["HARNESS_HELPER_LIVE"]!
        let node = HelperNode(), configuration = HelperNode.Configuration(enabled: true, hostName: host)
        let started = Date()
        let ready = await node.ensureReady(configuration)
        let problem = await node.problem ?? ""
        #expect(ready, "\(problem)")
        let request = InferenceRequest(runtime: .backburner, modelIdentifier: "helper:qwen3-8b", messages: [.init(role: .user,
            content: #"段落「日時は10月20日です。」を「日時は10月27日です。」に直す指示を JSON 一つで: {"edits": [{"find": "…", "replace": "…"}]}。JSON だけ。"#)],
            maximumOutputTokens: 200, temperature: 0)
        var answer = ""
        for try await piece in await LocalInferenceService().events(for: request) { answer += piece }
        #expect(answer.contains("10月27日"), "\(answer)")
        print("補助の Mac: 準備と 1 件で \(Int(Date().timeIntervalSince(started))) 秒 / \(answer.prefix(120))")
        await node.stop(configuration)
    }
}

/// Split reading is offered only when the helper is on and named (2026-10-21); otherwise Backburner reads alone.
@Test func splitReadingNeedsTheHelperSwitchedOn() async {
    let off = HelperNode.Configuration(enabled: false, hostName: "example-air")
    #expect(await HelperNode().prepareSplitTail(off) == nil)
    let unnamed = HelperNode.Configuration(enabled: true, hostName: "")
    #expect(await HelperNode().prepareSplitTail(unnamed) == nil)
}

/// The helper's memory and heat decide which roles it keeps (2026-10-21): the light model goes first, then the tail.
@Test func helperRolesAreLetGoWhenMemoryRunsShortOrItRunsHot() throws {
    let calm = "System-wide memory free percentage: 33%\nNote: No thermal warning level has been recorded\n"
    let health = try #require(HelperResourcePolicy.health(from: calm))
    #expect(health == .init(freePercent: 33, thermalWarning: false))
    #expect(HelperResourcePolicy.rolesToRelease(health).isEmpty)
    #expect(HelperResourcePolicy.rolesToRelease(.init(freePercent: 15, thermalWarning: false)) == [.lightModel])
    #expect(HelperResourcePolicy.rolesToRelease(.init(freePercent: 50, thermalWarning: true)) == [.lightModel])
    #expect(HelperResourcePolicy.rolesToRelease(.init(freePercent: 8, thermalWarning: false)) == [.lightModel, .splitTail])
    let hot = "System-wide memory free percentage: 40%\nCPU_Scheduler_Limit \t= 100\nCPU_Available_CPUs \t= 8\nCPU_Speed_Limit \t= 70\n"
    #expect(HelperResourcePolicy.health(from: hot)?.thermalWarning == true)
    #expect(HelperResourcePolicy.health(from: "no numbers here") == nil)
}
