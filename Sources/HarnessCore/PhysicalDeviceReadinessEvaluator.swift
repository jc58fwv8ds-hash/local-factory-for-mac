import Foundation

public enum PhysicalDeviceReadinessEvaluator {
    public static func evaluate(
        device: PhysicalAppleDevice,
        project: PhysicalDeviceProjectConfiguration,
        preparation: DevicePreparationSnapshot? = nil
    ) -> PhysicalDeviceReadiness {
        var requirements: [PhysicalDeviceSetupRequirement] = []
        // Legacy inventory booleans cannot establish current device readiness.
        if preparation?.isReady(for: device.deviceIdentifier) != true {
            requirements.append(.verifyDeviceState)
        }
        if !project.isIOSApplication { requirements.append(.selectIOSApplication) }
        if project.signingStyle != .automatic { requirements.append(.selectAutomaticSigning) }
        if !project.hasDevelopmentTeam { requirements.append(.selectDevelopmentTeam) }
        if !project.hasUsableBundleIdentifier { requirements.append(.configureBundleIdentifier) }
        return PhysicalDeviceReadiness(
            device: device,
            project: project,
            requirements: requirements,
            preparation: preparation
        )
    }
}
