public struct LocalProjectValidationService: ProjectValidating, Sendable {
    private let swiftPackage: SwiftPackageValidationService
    private let xcode = XcodeProjectValidationService()

    public init(disableSwiftPMSandbox: Bool = false) {
        swiftPackage = SwiftPackageValidationService(
            disableSwiftPMSandbox: disableSwiftPMSandbox
        )
    }

    public func support(rootPath: String) async -> ProjectValidationSupport? {
        if let xcodeSupport = await xcode.support(rootPath: rootPath) {
            return xcodeSupport
        }
        return await swiftPackage.support(rootPath: rootPath)
    }

    public func validate(rootPath: String) async throws -> ProjectValidationReport {
        if await xcode.support(rootPath: rootPath) != nil {
            return try await xcode.validate(rootPath: rootPath)
        }
        if await swiftPackage.support(rootPath: rootPath) != nil {
            return try await swiftPackage.validate(rootPath: rootPath)
        }
        throw ProjectValidationError.unsupportedProject
    }
}
