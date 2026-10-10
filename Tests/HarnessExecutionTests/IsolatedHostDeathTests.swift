import Darwin
import Foundation
import Testing
import HarnessCore
@testable import HarnessExecution

@Suite(.serialized) struct IsolatedHostDeathTests {
    @Test(arguments: ["build", "test", "descendant", "orphaned"])
    func realHostSIGKILLAndRestart(mode: String) async throws {
        let fm = FileManager.default
        let candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let root = candidate.appendingPathComponent("work/host-death-" + UUID().uuidString)
        let stable = root.appendingPathComponent("stable-fixture")
        try fm.createDirectory(at: root.appendingPathComponent("Sources/Probe"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Tests/ProbeTests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: stable, withIntermediateDirectories: true)
        try Data("protected".utf8).write(to: stable.appendingPathComponent("unchanged"))
        defer { try? fm.removeItem(at: root) }
        let marker = root.appendingPathComponent(".harness-execution/child.pid")
        let forkMarker = root.appendingPathComponent(".harness-execution/grandchild.pid")
        // The intermediate process exits first: the grandchild is reparented to launchd
        // and is unreachable through parent links, but stays in the owned process group.
        // Only async-signal-safe calls run between fork and exit.
        let orphan = "typealias Fork = @convention(c) () -> Int32; let fork = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), \"fork\")!, to: Fork.self); let path = strdup(\"\(forkMarker.path)\")!; let a = fork(); if a == 0 { if fork() == 0 { var me = getpid(); let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644); _ = write(fd, &me, 4); close(fd); sleep(30); _exit(0) }; _exit(0) }; var status: Int32 = 0; _ = waitpid(a, &status, 0)"
        let body = """
        let marker = "\(marker.path)"
        if !FileManager.default.fileExists(atPath: marker) {
            \(mode == "orphaned" ? orphan : "")
            \(mode == "descendant" ? "typealias Fork = @convention(c) () -> Int32; let fork = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), \"fork\")!, to: Fork.self); let child = fork(); if child == 0 { _ = setsid(); sleep(30); _exit(0) }; try String(child).write(toFile: \"\(forkMarker.path)\", atomically: true, encoding: .utf8)" : "")
            try String(getpid()).write(toFile: marker, atomically: true, encoding: .utf8)
            sleep(30)
        }
        """
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        import Foundation
        import Darwin
        \(mode == "build" ? body : "")
        let package = Package(name: "Probe", platforms: [.macOS(.v14)], targets: [.target(name: "Probe"), .testTarget(name: "ProbeTests", dependencies: ["Probe"])])
        """
        try manifest.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public let value = 1".write(to: root.appendingPathComponent("Sources/Probe/Probe.swift"), atomically: true, encoding: .utf8)
        try "import Testing\nimport Foundation\nimport Darwin\n@Test func slow() throws {\n\(mode == "build" ? "" : body)\n}\n".write(to: root.appendingPathComponent("Tests/ProbeTests/ProbeTests.swift"), atomically: true, encoding: .utf8)
        let evidence = root.appendingPathComponent("receipts")
        func launch() throws -> Process {
            let process = Process()
            process.executableURL = candidate.appendingPathComponent(".build/debug/HarnessKernelPilot")
            process.arguments = ["--isolated-package-host", candidate.path, root.path, evidence.path, mode == "build" ? "build" : "test", stable.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); return process
        }
        let host = try launch()
        defer { if host.isRunning { host.terminate() } }
        for _ in 0..<150 {
            if fm.fileExists(atPath: marker.path), mode == "build" || mode == "test" || ((try? Data(contentsOf: forkMarker))?.count ?? 0) >= 4 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard fm.fileExists(atPath: marker.path) else { Issue.record("Isolated child did not start: \(mode)"); return }
        let child = try #require(ExecutionProcessIdentity.read(Int32(String(contentsOf: marker, encoding: .utf8))!))
        let grandchild: ExecutionProcessIdentity? = switch mode {
        case "descendant": ExecutionProcessIdentity.read(Int32(try String(contentsOf: forkMarker, encoding: .utf8))!)
        case "orphaned": ExecutionProcessIdentity.read(try Data(contentsOf: forkMarker).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        default: nil
        }
        defer { if let grandchild, grandchild.isAlive { kill(grandchild.pid, SIGKILL) } } // hygiene only
        if mode != "build" && mode != "test" { #expect(grandchild != nil) }
        // The descendant leaves the child's session/group; recovery must not rely on group signals.
        if mode == "descendant", let grandchild { #expect(getsid(grandchild.pid) != getsid(child.pid)) }
        if mode == "orphaned", let grandchild {
            var info = proc_bsdinfo()
            _ = proc_pidinfo(grandchild.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            #expect(info.pbi_ppid == 1 && getpgid(grandchild.pid) == getpgid(child.pid))
        }
        // A second host cannot enter the same worktree while the first owns its lease.
        let duplicate = try launch()
        for _ in 0..<50 { if !duplicate.isRunning { break }; try await Task.sleep(for: .milliseconds(50)) }
        #expect(!duplicate.isRunning && duplicate.terminationStatus != 0)
        #expect(kill(host.processIdentifier, SIGKILL) == 0)
        for _ in 0..<100 {
            if !host.isRunning && !child.isAlive && grandchild?.isAlive != true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!child.isAlive)
        #expect(grandchild?.isAlive != true)
        // Guardian exits only after its terminal receipt is persisted.
        for _ in 0..<50 {
            let sessions = try fm.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("session-") }
            if sessions.allSatisfy({ (try? ExecutionSupervisor.verifyStopped(directory: $0)) != nil }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let restarted = try launch()
        for _ in 0..<150 { if !restarted.isRunning { break }; try await Task.sleep(for: .milliseconds(100)) }
        #expect(!restarted.isRunning && restarted.terminationStatus == 0)
        let receipts = try fm.contentsOfDirectory(at: evidence, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let states = try receipts.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(states.contains { $0.contains("INTERRUPTED_EXECUTION") && $0.contains("\"testResult\" : \"notVerified\"") && !$0.contains("commandPassed") })
        #expect(try fm.contentsOfDirectory(atPath: evidence.path).contains { $0.hasSuffix(".interrupted-original") })
        #expect(states.contains { $0.contains("commandPassed") })
        #expect(try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) == manifest)
        #expect(try String(contentsOf: stable.appendingPathComponent("unchanged"), encoding: .utf8) == "protected")
    }
}
