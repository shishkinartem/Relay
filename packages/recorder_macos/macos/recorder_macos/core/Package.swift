// swift-tools-version: 5.9

import PackageDescription

/// The recorder's Flutter-free core.
///
/// Everything here is pure: the wire contract shared with Dart, the geometry
/// that places the camera picture-in-picture, the canvas arithmetic, and the
/// one monotonic session timeline. None of it imports Flutter, AppKit or
/// ScreenCaptureKit, which is what makes it testable with `swift test` on any
/// machine — the plugin package around it declares a `FlutterFramework`
/// dependency that only resolves inside a Flutter build, so tests could never
/// run there.
///
/// It is nested inside the plugin package rather than beside it because Flutter
/// copies the plugin directory into `macos/Flutter/ephemeral/.packages/` at
/// build time. A sibling package would not be copied and the path dependency
/// would break; a child is carried along with its parent.
let package = Package(
    name: "RecorderCore",
    platforms: [
        .macOS("13.5")
    ],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"])
    ],
    targets: [
        .target(name: "RecorderCore"),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"])
    ]
)
