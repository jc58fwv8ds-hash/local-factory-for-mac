import Foundation
import HarnessCore
import Testing
@testable import HarnessApp

/// 2026-10-12, the user's request: an app installed on an iPhone with a free Apple account stops opening about 7 days
/// later; the app list shows the days left and the app reminds at launch when it is due.
struct DeviceInstallRecordTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    func at(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func theProfileIsReadFromTheEmbeddedPlist() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CreationDate": at(12, 9), "ExpirationDate": at(19, 9), "TeamName": "Taro Yamada"], format: .xml, options: 0)
        let profile = try #require(ProvisioningProfileReader.parse(plist))
        #expect(profile.isShortLived && profile.teamName == "Taro Yamada")
        let paid = ProvisioningProfile(createdAt: at(1), expiresAt: at(1).addingTimeInterval(365 * 86_400), teamName: "")
        #expect(!paid.isShortLived)
    }

    @Test func daysLeftAndTheReminder() {
        let record = DeviceInstallRecord(appKey: "/p", appName: "家計簿", deviceIdentifier: "D1", deviceName: "iPhone",
                                         installedAt: at(12), profile: .init(createdAt: at(12, 9), expiresAt: at(19, 9), teamName: ""))
        #expect(record.daysLeft(now: at(12), calendar: calendar) == 7)
        #expect(record.expiryNote(now: at(14), calendar: calendar) == "iPhone: 署名の期限まであと 5 日")
        #expect(!record.needsReinstall(now: at(14), calendar: calendar))
        #expect(record.needsReinstall(now: at(18), calendar: calendar))
        #expect(record.expiryNote(now: at(19, 8), calendar: calendar) == "iPhone: 今日で署名の期限が切れます。入れ直してください")
        #expect(record.expiryNote(now: at(19, 10), calendar: calendar) == "iPhone: 署名の期限が切れました。入れ直すとまた使えます")
        // A paid account's year-long profile is not mentioned until its last two weeks.
        let paid = DeviceInstallRecord(appKey: "/p", appName: "家計簿", deviceIdentifier: "D1", deviceName: "iPhone",
                                       profile: .init(createdAt: at(1), expiresAt: at(1).addingTimeInterval(365 * 86_400), teamName: ""))
        #expect(paid.expiryNote(now: at(12), calendar: calendar) == nil)
    }

    @Test func aNewInstallReplacesTheRecordForTheSameDevice() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("installs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DeviceInstallRecordStore(file: folder.appendingPathComponent("device-installs.json"))
        let profile = ProvisioningProfile(createdAt: at(12), expiresAt: at(19), teamName: "")
        store.record(.init(appKey: "/p", appName: "A", deviceIdentifier: "D1", deviceName: "iPhone", installedAt: at(12), profile: profile))
        store.record(.init(appKey: "/p", appName: "A", deviceIdentifier: "D2", deviceName: "iPad", installedAt: at(12), profile: profile))
        store.record(.init(appKey: "/p", appName: "A", deviceIdentifier: "D1", deviceName: "iPhone", installedAt: at(15),
                           profile: .init(createdAt: at(15), expiresAt: at(22), teamName: "")))
        let records = store.load()
        #expect(records.count == 2)
        #expect(records.first { $0.deviceIdentifier == "D1" }?.profile?.expiresAt == at(22))
    }
}

/// One press of 入れ直す installs the recorded app on the recorded device again and renews the expiry.
@MainActor
struct ReinstallTests {
    struct Library: AppleAppLibraryProviding {
        let app: InstallableAppleApp
        let device: PhysicalAppleDevice
        let installs: Counter
        func discoverApps(in sources: [AppleAppSource]) async throws -> [InstallableAppleApp] { [app] }
        func listDevices() async throws -> [PhysicalAppleDevice] { [device] }
        func install(_ app: InstallableAppleApp, on device: PhysicalAppleDevice,
                     onStage: @escaping @Sendable (AppleAppInstallStage) async -> Void) async throws -> AppleAppInstallReport {
            await installs.add()
            let now = Date()
            return AppleAppInstallReport(appName: app.displayName, deviceName: device.name, platform: device.platform,
                                         deviceIdentifier: device.deviceIdentifier,
                                         profile: .init(createdAt: now, expiresAt: now.addingTimeInterval(7 * 86_400), teamName: ""))
        }
    }

    actor Counter {
        var value = 0
        func add() { value += 1 }
    }

    @Test func oneButtonReinstallsAndRenewsTheExpiry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reinstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = AppleAppSource(projectID: UUID(), projectName: "家計簿", rootPath: "/tmp/kakeibo")
        let app = InstallableAppleApp(id: "kakeibo", source: source, container: .init(kind: .project, relativePath: "Kakeibo.xcodeproj"),
                                      scheme: "Kakeibo", displayName: "家計簿",
                                      configurations: [.init(platform: .iPhone, scheme: "Kakeibo", productName: "Kakeibo",
                                                             bundleIdentifier: "example.kakeibo", signingStyle: .automatic,
                                                             hasDevelopmentTeam: true)])
        let device = PhysicalAppleDevice(id: "D1", name: "iPhone", modelName: "iPhone", osVersion: "27.0", connection: .wired,
                                         isPaired: true, isDeveloperModeEnabled: true, isBooted: true)
        let counter = Counter()
        let session = AppleAppLibrarySession(sources: [source], provider: Library(app: app, device: device, installs: counter))
        session.installRecordStore = DeviceInstallRecordStore(file: folder.appendingPathComponent("installs.json"))
        session.refresh()
        for _ in 0..<100 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }

        let old = Date().addingTimeInterval(-8 * 86_400)
        let expired = DeviceInstallRecord(appKey: "/tmp/kakeibo", appName: "家計簿", deviceIdentifier: "D1", deviceName: "iPhone",
                                          installedAt: old, profile: .init(createdAt: old, expiresAt: old.addingTimeInterval(7 * 86_400), teamName: ""))
        #expect(expired.needsReinstall())
        #expect(session.reinstall(expired) == nil)
        for _ in 0..<100 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await counter.value == 1)
        #expect(session.statusMessage?.contains("入れ直しました") == true)
        let renewed = try #require(session.installRecordStore.load().first)
        #expect(renewed.daysLeft() == 7 && !renewed.needsReinstall())

        // Not connected: it says what to do instead of failing silently.
        let elsewhere = DeviceInstallRecord(appKey: "/tmp/kakeibo", appName: "家計簿", deviceIdentifier: "D9", deviceName: "iPad",
                                            profile: expired.profile)
        #expect(session.reinstall(elsewhere)?.contains("iPad が見つかりません") == true)
    }
}
