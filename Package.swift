// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swiftus",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Swiftus", targets: ["Swiftus"]),
        .library(name: "SwiftusCore", targets: ["SwiftusCore"]),
        .library(name: "SwiftusFoundation", targets: ["SwiftusFoundation"]),
        .library(name: "SwiftusCredentials", targets: ["SwiftusCredentials"]),
        .library(name: "SwiftusLLM", targets: ["SwiftusLLM"]),
        .library(name: "SwiftusCompaction", targets: ["SwiftusCompaction"]),
        .library(name: "SwiftusSearch", targets: ["SwiftusSearch"]),
        .library(name: "SwiftusSkill", targets: ["SwiftusSkill"]),
        .library(name: "SwiftusMCP", targets: ["SwiftusMCP"]),
        .library(name: "SwiftusSchedule", targets: ["SwiftusSchedule"]),
        .library(name: "SwiftusCron", targets: ["SwiftusCron"]),
        .library(name: "SwiftusAgent", targets: ["SwiftusAgent"]),
        .library(name: "SwiftusTasks", targets: ["SwiftusTasks"]),
        .executable(name: "swiftus-demo", targets: ["SwiftusRunner"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(name: "SwiftusCore"),
        .target(name: "SwiftusFoundation", dependencies: ["SwiftusCore"]),
        .target(name: "SwiftusCredentials", dependencies: ["SwiftusCore"]),
        .target(name: "SwiftusLLM", dependencies: ["SwiftusCore", "SwiftusCredentials"]),
        .target(name: "SwiftusCompaction", dependencies: ["SwiftusCore", "SwiftusFoundation"]),
        .target(name: "SwiftusSearch", dependencies: ["SwiftusCore", "SwiftusCredentials", "SwiftusFoundation"]),
        .target(name: "SwiftusSkill", dependencies: [
            "SwiftusCore", "SwiftusFoundation",
            .product(name: "Yams", package: "Yams"),
        ]),
        .target(name: "SwiftusMCP", dependencies: ["SwiftusCore", "SwiftusCredentials", "SwiftusFoundation"]),
        .target(name: "SwiftusSchedule", dependencies: ["SwiftusCore", "SwiftusFoundation"]),
        .target(name: "SwiftusCron", dependencies: ["SwiftusCore", "SwiftusFoundation"]),
        .target(name: "SwiftusAgent", dependencies: ["SwiftusCore", "SwiftusFoundation", "SwiftusLLM", "SwiftusCompaction", "SwiftusSchedule"]),
        .target(name: "SwiftusTasks", dependencies: ["SwiftusCore", "SwiftusFoundation", "SwiftusAgent", "SwiftusSchedule"]),
        .target(name: "Swiftus", dependencies: [
            "SwiftusCore", "SwiftusFoundation", "SwiftusCredentials", "SwiftusLLM",
            "SwiftusCompaction", "SwiftusSearch", "SwiftusSkill", "SwiftusMCP",
            "SwiftusSchedule", "SwiftusCron", "SwiftusAgent", "SwiftusTasks",
        ]),
        .target(name: "SwiftusDemo", dependencies: [
            "SwiftusCore", "SwiftusFoundation", "SwiftusLLM", "SwiftusSkill",
        ]),
        .executableTarget(name: "SwiftusRunner", dependencies: ["SwiftusDemo"]),
        .testTarget(name: "SwiftusCoreTests", dependencies: ["SwiftusCore"]),
        .testTarget(name: "SwiftusCredentialsTests", dependencies: ["SwiftusCredentials"]),
        .testTarget(name: "SwiftusLLMTests", dependencies: ["SwiftusLLM", "SwiftusCredentials"]),
        .testTarget(name: "SwiftusFoundationTests", dependencies: ["SwiftusFoundation"]),
        .testTarget(name: "SwiftusCompactionTests", dependencies: ["SwiftusCompaction", "SwiftusFoundation"]),
        .testTarget(name: "SwiftusScheduleTests", dependencies: ["SwiftusSchedule", "SwiftusFoundation"]),
        .testTarget(name: "SwiftusCronTests", dependencies: ["SwiftusCron", "SwiftusFoundation"]),
        .testTarget(name: "SwiftusSearchTests", dependencies: [
            "SwiftusSearch", "SwiftusCredentials", "SwiftusFoundation",
        ]),
        .testTarget(name: "SwiftusAgentTests", dependencies: ["SwiftusAgent", "SwiftusCompaction", "SwiftusFoundation", "SwiftusLLM"]),
        .testTarget(name: "SwiftusSkillTests", dependencies: ["SwiftusSkill", "SwiftusFoundation"]),
        .testTarget(name: "SwiftusTasksTests", dependencies: [
            "SwiftusTasks", "SwiftusAgent", "SwiftusFoundation", "SwiftusSchedule",
        ]),
        .testTarget(name: "SwiftusDemoTests", dependencies: ["SwiftusDemo"]),
    ]
)
