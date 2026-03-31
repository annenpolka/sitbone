// swift-tools-version: 6.0
import PackageDescription

let commonSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Sitbone",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Sitbone",
            dependencies: ["SitboneUI"],
            resources: [.process("Resources")],
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SitboneUI",
            dependencies: ["SitboneCore"],
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SitboneCore",
            dependencies: ["SitboneSensors", "SitboneData"],
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SitboneSensors",
            swiftSettings: commonSwiftSettings
        ),
        .target(
            name: "SitboneData",
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SitboneCoreTests",
            dependencies: ["SitboneCore"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SitboneSensorsTests",
            dependencies: ["SitboneSensors"],
            swiftSettings: commonSwiftSettings
        ),
        .testTarget(
            name: "SitboneUITests",
            dependencies: ["SitboneUI"],
            swiftSettings: commonSwiftSettings
        ),
    ]
)
