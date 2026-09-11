// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaterialOrganizer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrganizerCore", targets: ["OrganizerCore"]),
        .executable(name: "MaterialOrganizer", targets: ["MaterialOrganizer"]),
        .executable(name: "OrganizerSmoke", targets: ["OrganizerSmoke"])
    ],
    targets: [
        .target(name: "OrganizerCore"),
        .target(name: "OrganizerMotion"),
        .executableTarget(name: "MaterialOrganizer", dependencies: ["OrganizerCore", "OrganizerMotion"], resources: [.process("Resources")]),
        .executableTarget(name: "OrganizerSmoke", dependencies: ["OrganizerCore"]),
        .testTarget(name: "OrganizerCoreTests", dependencies: ["OrganizerCore"]),
        .testTarget(name: "OrganizerMotionTests", dependencies: ["OrganizerMotion"]),
        .testTarget(name: "MaterialOrganizerTests", dependencies: ["MaterialOrganizer"])
    ],
    swiftLanguageModes: [.v5]
)
