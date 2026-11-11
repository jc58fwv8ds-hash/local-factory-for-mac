import Foundation
import HarnessCore

/// Free-account signatures renewed without being asked (2026-11-11, the user: 「無料署名とかの設定もアプリが自動で行う
/// ようにしてほしい」). While the app is open, an app it installed whose profile runs out within a day is installed again on
/// the same device when that device is connected; the install renews the profile (ProvisioningProfileRenewal) and the new
/// date is told. A device that is not connected is tried again later.
extension WorkspaceStore {
    func renewExpiringSignatures(records: DeviceInstallRecordStore = .standard) async {
        let due = records.load().filter { $0.needsReinstall() }
        guard !due.isEmpty, !SigningRenewalState.shared.isRunning else { return }
        SigningRenewalState.shared.isRunning = true
        defer { SigningRenewalState.shared.isRunning = false }
        let provider = appleAppLibraryProvider
        guard let apps = try? await provider.discoverApps(in: appleAppSources),
              let devices = try? await provider.listDevices() else { return }
        var renewed: [String] = []
        for record in due {
            guard let app = apps.first(where: { $0.source.rootPath == record.appKey }),
                  let device = devices.first(where: { $0.deviceIdentifier == record.deviceIdentifier }) else { continue }
            guard let report = try? await provider.install(app, on: device, onStage: { _ in }) else { continue }
            let fresh = DeviceInstallRecord(appKey: record.appKey, appName: report.appName, deviceIdentifier: report.deviceIdentifier,
                                            deviceName: report.deviceName, profile: report.profile)
            if report.profile != nil { _ = records.record(fresh) }
            renewed.append("\(report.appName)(\(report.deviceName)、" + (fresh.expiryNote() ?? "期限は不明") + ")")
        }
        if !renewed.isEmpty {
            presentNotice("署名の期限が近いアプリを自動で入れ直しました: " + renewed.joined(separator: "、"), kind: .information)
        }
    }
}

@MainActor
final class SigningRenewalState {
    static let shared = SigningRenewalState()
    var isRunning = false
}
