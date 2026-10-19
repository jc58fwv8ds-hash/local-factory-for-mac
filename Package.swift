// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Harness", targets: ["HarnessApp"]),
        .executable(name: "HarnessCoreChecks", targets: ["HarnessCoreChecks"]),
        .executable(name: "HarnessKernelPilot", targets: ["HarnessKernelPilot"]),
        .executable(name: "HarnessIOSPilot", targets: ["HarnessIOSPilot"]),
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        .library(name: "HarnessKernel", targets: ["HarnessKernel"])
    ],
    targets: [
        .target(name: "HarnessKernelContracts"),
        .target(name: "HarnessKernel", dependencies: ["HarnessKernelContracts"]),
        .target(name: "HarnessKernelPersistence", dependencies: ["HarnessKernelContracts"]),
        .target(
            name: "HarnessExecution",
            dependencies: ["HarnessCore", "HarnessKernel", "HarnessKernelPersistence"]
        ),
        .target(name: "TaskOrchestrator", dependencies: ["HarnessCore", "HarnessKernel", "HarnessExecution"]),
        .executableTarget(name: "HarnessKernelPilot", dependencies: ["HarnessExecution", "TaskOrchestrator"]),
        .executableTarget(name: "HarnessIOSPilot", dependencies: ["HarnessExecution"]),
        .target(name: "HarnessCore"),
        .executableTarget(
            name: "HarnessApp",
            dependencies: ["HarnessCore", "HarnessExecution", "TaskOrchestrator"],
            resources: [
                .copy("Resources/qwen3_tts_worker.py"),
                .copy("Resources/qwen3_tts_server.py"),
                .copy("Resources/voice_engine_install_worker.py"),
                .copy("Resources/VoiceEngineRuntime")
            ]
        ),
        .executableTarget(
            name: "HarnessCoreChecks",
            dependencies: ["HarnessCore"]
        ),
        .testTarget(
            name: "HarnessExecutionTests",
            dependencies: ["HarnessExecution"]
        ),
        .testTarget(
            name: "HarnessKernelTests",
            dependencies: ["HarnessKernel", "HarnessKernelPersistence"]
        ),
        .testTarget(
            name: "TaskOrchestratorTests",
            dependencies: ["TaskOrchestrator"]
        ),
        .testTarget(
            name: "HarnessAppTests",
            dependencies: ["HarnessApp", "TaskOrchestrator"]
        )
    ]
)
