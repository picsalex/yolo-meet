// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "YoloMeet",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "YoloMeetCore", swiftSettings: settings),
        // Story assets (3D models, images, sounds) are copied into the app by scripts/build.sh, not compiled.
        .executableTarget(
            name: "YoloMeet", dependencies: ["YoloMeetCore"], exclude: ["Stories/README.md", "Stories/Assets"],
            swiftSettings: settings),
        .testTarget(name: "YoloMeetCoreTests", dependencies: ["YoloMeetCore"]),
    ]
)
