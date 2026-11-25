import Foundation
import Testing
@testable import HarnessCore

struct DeveloperDataTests {
    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dev-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func folder(_ url: URL, daysOld: Double, bytes: Int = 10) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url.appendingPathComponent("f"))
        let date = Date().addingTimeInterval(-daysOld * 86_400)
        for item in [url.appendingPathComponent("f"), url] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
        }
    }

    final class Trash: @unchecked Sendable {
        var moved: [String] = []
        func take(_ url: URL) throws { moved.append(url.lastPathComponent); try FileManager.default.removeItem(at: url) }
    }

    @Test func derivedDataOfFactoryProjectsGoesAfterADayOthersAfterTwoWeeks() throws {
        let home = try scratch(); defer { try? FileManager.default.removeItem(at: home) }
        let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let projects = home.appendingPathComponent("Library/Application Support/Harness/Projects").path
        func project(_ name: String, workspace: String, daysOld: Double) throws {
            let url = derived.appendingPathComponent(name)
            try folder(url, daysOld: daysOld)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace], format: .xml, options: 0)
            try plist.write(to: url.appendingPathComponent("info.plist"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)],
                                                  ofItemAtPath: url.appendingPathComponent("info.plist").path)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
        }
        try project("Factory-old", workspace: projects + "/FourteenTranslate/App.xcodeproj", daysOld: 2)
        try project("Factory-today", workspace: projects + "/FourteenTranslate/App.xcodeproj", daysOld: 0.01)
        try project("Other-week", workspace: "/Users/x/Code/Mine.xcodeproj", daysOld: 7)
        try project("Other-month", workspace: "/Users/x/Code/Old.xcodeproj", daysOld: 30)
        let trash = Trash()
        let report = DeveloperDataJanitor(home: home, temporary: try scratch(), trash: trash.take).sweep()
        #expect(Set(trash.moved) == ["Factory-old", "Other-month"])
        #expect(report.moved.count == 2)
    }

    @Test func deviceSupportKeepsTheNewestAndRecentlyUsedVersions() throws {
        let home = try scratch(); defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")
        try folder(support.appendingPathComponent("26.5 (23F77)"), daysOld: 60)
        try folder(support.appendingPathComponent("27.1 (24B10)"), daysOld: 5)
        try folder(support.appendingPathComponent("27.2.1 (24C20)"), daysOld: 90)
        let trash = Trash()
        _ = DeveloperDataJanitor(home: home, temporary: try scratch(), trash: trash.take).sweep()
        #expect(trash.moved == ["26.5 (23F77)"])
    }

    @Test func onlyFactorysOwnOldTemporaryFoldersAreRemoved() throws {
        let temporary = try scratch(); defer { try? FileManager.default.removeItem(at: temporary) }
        try folder(temporary.appendingPathComponent("HarnessDerivedData-OLD"), daysOld: 2)
        try folder(temporary.appendingPathComponent("HarnessDerivedData-NOW"), daysOld: 0)
        try folder(temporary.appendingPathComponent("SomeoneElse-OLD"), daysOld: 9)
        _ = DeveloperDataJanitor(home: try scratch(), temporary: temporary, trash: { _ in Issue.record("trash used") }).sweep()
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path))
        #expect(left == ["HarnessDerivedData-NOW", "SomeoneElse-OLD"])
    }

    @Test func aProjectKeepsOneBuildFolderHeldByOneCheckAtATime() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let project = URL(fileURLWithPath: "/tmp/Projects/FourteenTranslate")
        let first = try #require(BuildCache.checkOut(project: project, stamp: "Xcode A", root: root))
        #expect(BuildCache.checkOut(project: project, stamp: "Xcode A", root: root) == nil)
        try Data("o".utf8).write(to: first.appendingPathComponent("built.o"))
        BuildCache.checkIn(first, root: root)
        let again = try #require(BuildCache.checkOut(project: project, stamp: "Xcode A", root: root))
        #expect(again == first && FileManager.default.fileExists(atPath: again.appendingPathComponent("built.o").path))
        BuildCache.checkIn(again, root: root)
        // Another Xcode: the folder starts anew.
        let other = try #require(BuildCache.checkOut(project: project, stamp: "Xcode B", root: root))
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("built.o").path))
        BuildCache.checkIn(other, root: root)
    }

    @Test func theCacheIsTrimmedLeastRecentlyUsedFirst() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try folder(root.appendingPathComponent("old"), daysOld: 3, bytes: 300_000)
        try folder(root.appendingPathComponent("new"), daysOld: 1, bytes: 300_000)
        let current = try #require(BuildCache.checkOut(project: URL(fileURLWithPath: "/tmp/P"), stamp: "x", root: root))
        try Data(count: 300_000).write(to: current.appendingPathComponent("o"))
        BuildCache.checkIn(current, root: root, limit: 700_000)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left == ["new", current.lastPathComponent])
    }

    @Test func aStaleCacheIsEmptiedOnlyForCacheErrors() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try #require(BuildCache.checkOut(project: URL(fileURLWithPath: "/tmp/Q"), stamp: "x", root: root))
        try Data("o".utf8).write(to: folder.appendingPathComponent("built.o"))
        #expect(!BuildCache.clearIfStale(folder, output: "error: cannot find 'foo' in scope"))
        #expect(BuildCache.clearIfStale(folder, output: "error: PCH was compiled with module cache path '/x', but the path is currently '/y'"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("built.o").path))
        BuildCache.checkIn(folder, root: root)
    }

    @Test func theTestDeviceStaysTheSame() {
        func device(_ id: String, _ name: String, _ runtime: String, booted: Bool = false) -> SimulatorDevice {
            SimulatorDevice(id: id, name: name, runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-\(runtime)",
                            runtimeName: "iOS", state: booted ? .booted : .shutdown)
        }
        let a = device(UUID().uuidString, "iPhone 17", "26-5"), b = device(UUID().uuidString, "iPhone 17", "27-0")
        let c = device(UUID().uuidString, "iPhone 14 Pro", "27-0")
        #expect(XcodeTestDestinationSelector.preferred(from: [a, b, c])?.id == b.id)               // newest runtime
        #expect(XcodeTestDestinationSelector.preferred(from: [a, b, c], last: c.id)?.id == c.id)   // the one used last
        let booted = device(UUID().uuidString, "iPhone Air", "26-5", booted: true)
        #expect(XcodeTestDestinationSelector.preferred(from: [a, booted, c], last: c.id)?.id == booted.id)
    }
}
