// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "YoloMeet",
    // iOS is for PenLink alone: the iPad pen app (iPad/) builds it from this package.
    platforms: [.macOS("27.0"), .iOS("18.0")],
    products: [.library(name: "PenLink", targets: ["PenLink"])],
    targets: [
        .target(name: "YoloMeetCore", swiftSettings: settings),
        // What yolo-meet and the iPad pen app say to each other, and the connection between them.
        .target(name: "PenLink", swiftSettings: settings),
        // Story assets (3D models, images, sounds) are copied into the app by scripts/build.sh, not compiled.
        .executableTarget(
            name: "YoloMeet", dependencies: ["YoloMeetCore", "PenLink"], exclude: ["Stories/README.md", "Stories/Assets"],
            swiftSettings: settings),
        .testTarget(name: "YoloMeetCoreTests", dependencies: ["YoloMeetCore"]),
        .testTarget(name: "PenLinkTests", dependencies: ["PenLink"], swiftSettings: settings),
    ]
)
