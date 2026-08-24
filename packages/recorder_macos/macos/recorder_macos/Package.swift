// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "recorder_macos",
    platforms: [
        .macOS("13.5")
    ],
    products: [
        .library(name: "recorder-macos", targets: ["recorder_macos"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // The Flutter-free half, nested rather than beside this package so it
        // travels with it when Flutter copies the plugin into
        // `macos/Flutter/ephemeral/.packages/`. It is where the pure contract,
        // geometry and timing live, and the only part of this plugin that
        // `swift test` can reach without a Flutter build.
        .package(name: "RecorderCore", path: "core")
    ],
    targets: [
        .target(
            name: "recorder_macos",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "RecorderCore", package: "RecorderCore")
            ],
            resources: [
                // If your plugin requires a privacy manifest, for example if it collects user
                // data, update the PrivacyInfo.xcprivacy file to describe your plugin's
                // privacy impact, and then uncomment these lines. For more information, see
                // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
                // .process("PrivacyInfo.xcprivacy"),

                // If you have other resources that need to be bundled with your plugin, refer to
                // the following instructions to add them:
                // https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package
            ]
        )
    ]
)
