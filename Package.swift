// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
]

let package = Package(
    name: "AeroSpacePackage",
    // Runtime support for parameterized protocol types is only available in macOS 13.0.0 or newer
    // And it specifies deploymentTarget for CLI
    platforms: [.macOS(.v13)],
    // Products define the executables and libraries a package produces, making them visible to other packages.
    products: [
        .executable(name: "aerospace", targets: ["Cli"]),
        // Don't use this build for release, use xcode instead
        .executable(name: "AeroSpaceApp", targets: ["AeroSpaceApp"]),
        // We only need to expose this as a product for xcode
        .library(name: "AppBundle", targets: ["AppBundle"]),
        // skyland: window animation styles, played by the Dock payload (osax/payload.m `track`)
        .library(name: "SkylandAnimation", targets: ["SkylandAnimation"]),
        // skyland: tries the SkylandAnimation styles on a real window
        .executable(name: "skyland-anim", targets: ["SkylandAnimDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/InerziaSoft/ISSoundAdditions.git", exact: "2.0.1"),
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.4"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.3.0"),
        .package(url: "https://github.com/soffes/HotKey.git", exact: "0.2.1"),
    ],
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    targets: [
        // Exposes the private _AXUIElementGetWindow function to swift
        .target(
            name: "PrivateApi",
            path: "Sources/PrivateApi",
            publicHeadersPath: "include",
        ),
        .target(
            name: "Common",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
            ],
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "AppBundle",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "HotKey", package: "HotKey"),
                .product(name: "ISSoundAdditions", package: "ISSoundAdditions"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
                .target(name: "Common"),
                .target(name: "PrivateApi"),
                .target(name: "SkylandAnimation"), // skyland: animation styles as payload tracks
            ],
            swiftSettings: swiftSettings,
        ),
        .executableTarget(
            name: "AeroSpaceApp",
            dependencies: [
                .target(name: "AppBundle"),
            ],
            swiftSettings: swiftSettings,
        ),
        .executableTarget(
            name: "Cli",
            dependencies: [
                .target(name: "Common"),
            ],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "AppBundleTests",
            dependencies: [
                .target(name: "AppBundle"),
            ],
            swiftSettings: swiftSettings,
        ),
        // skyland: Hyprland animation styles as tracks for the Dock payload, Foundation only
        .target(
            name: "SkylandAnimation",
            exclude: ["README.md"],
            swiftSettings: swiftSettings,
        ),
        .executableTarget(
            name: "SkylandAnimDemo",
            dependencies: [
                .target(name: "SkylandAnimation"),
            ],
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "SkylandAnimationTests",
            dependencies: [
                .target(name: "SkylandAnimation"),
            ],
            swiftSettings: swiftSettings,
        ),
    ],
)
