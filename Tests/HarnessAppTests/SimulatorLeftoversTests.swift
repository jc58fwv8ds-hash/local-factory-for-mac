import Foundation
@testable import HarnessCore
import Testing

struct SimulatorLeftoversTests {
    @Test func oldSimulatorAppsAreMovedOnlyWhenTheyAddUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sims-\(UUID().uuidString)")
        let dead = root.appendingPathComponent("DEVICE/data/Library/Caches/com.apple.containermanagerd/Dead/temp.A/App.app")
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        try Data(count: 4_096).write(to: dead.appendingPathComponent("model.gguf"))
        defer { try? FileManager.default.removeItem(at: root) }
        let found = SimulatorLeftovers.find(devicesRoot: root)
        #expect(found.folders.map(\.lastPathComponent) == ["temp.A"])
        #expect(found.bytes >= 4_096)
        var trashed: [URL] = []
        // Small: left alone.
        #expect(SimulatorLeftovers.moveToTrash(devicesRoot: root, trash: { trashed.append($0) }) == 0)
        #expect(trashed.isEmpty)
        #expect(SimulatorLeftovers.note(movedBytes: 0) == nil)
        // Enough: each leftover folder goes to the Trash.
        #expect(SimulatorLeftovers.moveToTrash(devicesRoot: root, minimum: 1, trash: { trashed.append($0) }) >= 4_096)
        #expect(trashed.map(\.lastPathComponent) == ["temp.A"])
        #expect(SimulatorLeftovers.note(movedBytes: 8 << 30)?.contains("8.0 GB") == true)
    }
}
