// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import PackageDescription

let package = Package(
    name: "Kinora",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KinoraKit", targets: ["KinoraKit"]),
    ],
    targets: [
        // Pure logic shared by the app and the wallpaper plug-in. No side effects, fully tested.
        .target(name: "KinoraKit"),
        // The app: library, settings, and selection.
        .executableTarget(name: "Kinora", dependencies: ["KinoraKit"]),
        // The com.apple.wallpaper plug-in. Like Apple's own wallpaper plug-ins it must start in
        // Foundation's NSExtensionMain, which sets up ExtensionKit before calling the Swift @main type.
        .executableTarget(
            name: "KinoraWallpaper",
            dependencies: ["KinoraKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(name: "KinoraKitTests", dependencies: ["KinoraKit"]),
    ]
)
