// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "YoloMeet",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "YoloMeetCore", swiftSettings: settings),
        .executableTarget(name: "YoloMeet", dependencies: ["YoloMeetCore"], swiftSettings: settings),
        .testTarget(name: "YoloMeetCoreTests", dependencies: ["YoloMeetCore"]),
    ]
)
