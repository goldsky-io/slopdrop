// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlopDrop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SlopDrop",
            resources: [
                .copy("Resources/slop-agent.js"),
                .copy("Resources/MenuBarMuting.png"),
                .copy("Resources/MenuBarMuting@2x.png"),
                .copy("Resources/MenuBarPaused.png"),
                .copy("Resources/MenuBarPaused@2x.png"),
                .copy("Resources/MenuBarDisconnected.png"),
                .copy("Resources/MenuBarDisconnected@2x.png"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
