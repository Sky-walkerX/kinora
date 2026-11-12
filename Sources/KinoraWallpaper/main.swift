// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import ExtensionFoundation

// The process starts in Foundation's NSExtensionMain (see Package.swift), which sets up
// ExtensionKit and then runs this type. Each WallpaperAgent connection is handed to the endpoint.
struct KinoraWallpaperExtension: AppExtension {
    init() {}

    var configuration: ConnectionHandler {
        ConnectionHandler { connection in XPCEndpoint.shared.accept(connection) }
    }
}

try KinoraWallpaperExtension.main()
