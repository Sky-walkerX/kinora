// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

/// Names that end up in other software's records, so they must never change after release.
/// The plug-in's bundle identifier is what macOS writes into the user's wallpaper settings.
public enum KinoraIdentity {
    public static let appBundleID = "io.github.sky-walkerx.kinora"
    public static let wallpaperBundleID = "io.github.sky-walkerx.kinora.wallpaper"

    /// WallpaperAgent records a choice's provider as the bundle identifier of the plug-in that drew it.
    public static let providerID = wallpaperBundleID

    /// The library lives here, relative to the real home folder. The sandboxed plug-in may read it
    /// through a read-only home-relative exception in its entitlements.
    public static let libraryRelativePath = "Library/Application Support/Kinora"

    /// Posted by the app when the library or settings change, so the plug-in reloads.
    public static let libraryChangedNotification = "io.github.sky-walkerx.kinora.library-changed"
}
