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
        // Media work the app does once, off the main thread: Living Photos (Vision, Core Image,
        // AVFoundation). Not linked into the plug-in, which only plays the result.
        .target(name: "KinoraMedia", dependencies: ["KinoraKit"]),
        // Kinora's own generative wallpapers, drawn with Metal by the plug-in and, for previews
        // and thumbnails, by the app.
        .target(name: "KinoraRender", dependencies: ["KinoraKit"]),
        // The app: library, settings, and selection.
        .executableTarget(name: "Kinora", dependencies: ["KinoraKit", "KinoraMedia", "KinoraRender"]),
        // The com.apple.wallpaper plug-in. Like Apple's own wallpaper plug-ins it must start in
        // Foundation's NSExtensionMain, which sets up ExtensionKit before calling the Swift @main type.
        .executableTarget(
            name: "KinoraWallpaper",
            dependencies: ["KinoraKit", "KinoraRender"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(name: "KinoraKitTests", dependencies: ["KinoraKit"]),
        .testTarget(name: "KinoraMediaTests", dependencies: ["KinoraMedia", "KinoraKit", "KinoraRender"]),
    ]
)
