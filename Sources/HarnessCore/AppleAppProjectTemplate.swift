enum AppleAppProjectTemplate {
    static func make(productName: String, bundleIdentifier: String) -> String {
        """
        // !$*UTF8*$!
        {
        	archiveVersion = 1;
        	classes = {};
        	objectVersion = 77;
        	objects = {

        /* Begin PBXContainerItemProxy section */
        		F00000000000000000000002 = {isa = PBXContainerItemProxy; containerPortal = G00000000000000000000001 /* Project object */; proxyType = 1; remoteGlobalIDString = A00000000000000000000001; remoteInfo = \(productName); };
        /* End PBXContainerItemProxy section */

        /* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
        		J00000000000000000000001 /* Exceptions for \(productName) in \(productName) */ = {isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (Info.plist); target = A00000000000000000000001 /* \(productName) */; };
        /* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

        /* Begin PBXFileReference section */
        		B00000000000000000000008 /* \(productName).app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \(productName).app; sourceTree = BUILT_PRODUCTS_DIR; };
        		B00000000000000000000009 /* \(productName)Tests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = \(productName)Tests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
        /* End PBXFileReference section */

        /* Begin PBXFileSystemSynchronizedRootGroup section */
        		D00000000000000000000002 /* \(productName) */ = {isa = PBXFileSystemSynchronizedRootGroup; exceptions = (J00000000000000000000001 /* Exceptions for \(productName) in \(productName) */); path = \(productName); sourceTree = "<group>"; };
        		D00000000000000000000003 /* \(productName)Tests */ = {isa = PBXFileSystemSynchronizedRootGroup; path = \(productName)Tests; sourceTree = "<group>"; };
        /* End PBXFileSystemSynchronizedRootGroup section */

        /* Begin PBXFrameworksBuildPhase section */
        		E00000000000000000000002 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        		E00000000000000000000005 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        /* End PBXFrameworksBuildPhase section */

        /* Begin PBXGroup section */
        		D00000000000000000000001 = {isa = PBXGroup; children = (D00000000000000000000002 /* \(productName) */, D00000000000000000000003 /* \(productName)Tests */, D00000000000000000000004 /* Products */); sourceTree = "<group>"; };
        		D00000000000000000000004 /* Products */ = {isa = PBXGroup; children = (B00000000000000000000008, B00000000000000000000009); name = Products; sourceTree = "<group>"; };
        /* End PBXGroup section */

        /* Begin PBXNativeTarget section */
        		A00000000000000000000001 /* \(productName) */ = {isa = PBXNativeTarget; buildConfigurationList = H00000000000000000000002; buildPhases = (E00000000000000000000001, E00000000000000000000002, E00000000000000000000003); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (D00000000000000000000002 /* \(productName) */); name = \(productName); productName = \(productName); productReference = B00000000000000000000008; productType = "com.apple.product-type.application"; };
        		A00000000000000000000002 /* \(productName)Tests */ = {isa = PBXNativeTarget; buildConfigurationList = H00000000000000000000003; buildPhases = (E00000000000000000000004, E00000000000000000000005, E00000000000000000000006); buildRules = (); dependencies = (F00000000000000000000001); fileSystemSynchronizedGroups = (D00000000000000000000003 /* \(productName)Tests */); name = \(productName)Tests; productName = \(productName)Tests; productReference = B00000000000000000000009; productType = "com.apple.product-type.bundle.unit-test"; };
        /* End PBXNativeTarget section */

        /* Begin PBXProject section */
        		G00000000000000000000001 /* Project object */ = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 2660; LastUpgradeCheck = 2660; TargetAttributes = {A00000000000000000000001 = {CreatedOnToolsVersion = 26.0;}; A00000000000000000000002 = {CreatedOnToolsVersion = 26.0; TestTargetID = A00000000000000000000001;};};}; buildConfigurationList = H00000000000000000000001; compatibilityVersion = "Xcode 16.0"; developmentRegion = ja; hasScannedForEncodings = 0; knownRegions = (ja, en, Base); mainGroup = D00000000000000000000001; preferredProjectObjectVersion = 77; productRefGroup = D00000000000000000000004; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000001, A00000000000000000000002); };
        /* End PBXProject section */

        /* Begin PBXResourcesBuildPhase section */
        		E00000000000000000000003 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        		E00000000000000000000006 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        /* End PBXResourcesBuildPhase section */

        /* Begin PBXSourcesBuildPhase section */
        		E00000000000000000000001 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        		E00000000000000000000004 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        /* End PBXSourcesBuildPhase section */

        /* Begin PBXTargetDependency section */
        		F00000000000000000000001 = {isa = PBXTargetDependency; target = A00000000000000000000001; targetProxy = F00000000000000000000002; };
        /* End PBXTargetDependency section */

        /* Begin XCBuildConfiguration section */
        		I00000000000000000000001 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_VERSION = 6.0;}; name = Debug; };
        		I00000000000000000000002 /* Release */ = {isa = XCBuildConfiguration; buildSettings = {ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SWIFT_COMPILATION_MODE = wholemodule; SWIFT_OPTIMIZATION_LEVEL = "-O"; SWIFT_VERSION = 6.0;}; name = Release; };
        		I00000000000000000000003 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = \(productName)/Info.plist; MARKETING_VERSION = 1.0; PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier); PRODUCT_NAME = "$(TARGET_NAME)"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SWIFT_EMIT_LOC_STRINGS = YES; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = 1;}; name = Debug; };
        		I00000000000000000000004 /* Release */ = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = \(productName)/Info.plist; MARKETING_VERSION = 1.0; PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier); PRODUCT_NAME = "$(TARGET_NAME)"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SWIFT_EMIT_LOC_STRINGS = YES; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = 1;}; name = Release; };
        		I00000000000000000000005 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {BUNDLE_LOADER = "$(TEST_HOST)"; CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier).tests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = 1; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/\(productName).app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/\(productName)";}; name = Debug; };
        		I00000000000000000000006 /* Release */ = {isa = XCBuildConfiguration; buildSettings = {BUNDLE_LOADER = "$(TEST_HOST)"; CODE_SIGN_STYLE = Automatic; GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; PRODUCT_BUNDLE_IDENTIFIER = \(bundleIdentifier).tests; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = 1; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/\(productName).app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/\(productName)";}; name = Release; };
        /* End XCBuildConfiguration section */

        /* Begin XCConfigurationList section */
        		H00000000000000000000001 = {isa = XCConfigurationList; buildConfigurations = (I00000000000000000000001, I00000000000000000000002); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        		H00000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (I00000000000000000000003, I00000000000000000000004); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        		H00000000000000000000003 = {isa = XCConfigurationList; buildConfigurations = (I00000000000000000000005, I00000000000000000000006); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        /* End XCConfigurationList section */
        	};
        	rootObject = G00000000000000000000001 /* Project object */;
        }
        """
    }
}
