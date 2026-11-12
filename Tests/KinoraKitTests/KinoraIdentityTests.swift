// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Testing
@testable import KinoraKit

@Suite struct KinoraIdentityTests {
    @Test func providerIsThePlugInBundleID() {
        #expect(KinoraIdentity.providerID == "io.github.sky-walkerx.kinora.wallpaper")
    }

    @Test func plugInIDIsNestedUnderTheAppID() {
        #expect(KinoraIdentity.wallpaperBundleID.hasPrefix(KinoraIdentity.appBundleID + "."))
    }
}
