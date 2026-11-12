// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation
import Testing
@testable import KinoraKit

/// Fixtures are requests WallpaperAgent sent the spike plug-in on macOS 27.0.1, trimmed of the
/// colour space blob.
@Suite struct WallpaperRequestTests {
    static let desktopAcquire = #"{"configuration":"eyJ2aWRlbyI6InNwaWtlIn0=","activityState":{"active":{}},"presentationMode":{"default":{}},"debugBackgrounds":false,"isPreview":false,"systemAppearance":{"dark":{}},"destination":{"scaleFactor":2,"directDisplayID":1,"size":[1470,956],"colorSpace":"YnBsaXN0"}}"#
    static let previewAcquire = #"{"presentationMode":{"default":{}},"debugBackgrounds":false,"isPreview":true,"optionValues":{"values":{}},"destination":{"directDisplayID":1,"size":[1470,956],"colorSpace":"YnBsaXN0","scaleFactor":2},"activityState":{"active":{}},"systemAppearance":{"dark":{}}}"#
    static let lockUpdate = #"{"presentationMode":{"locked":{}},"activityState":{"active":{}},"systemAppearance":{"dark":{}},"debugBackgrounds":false,"destination":{"directDisplayID":1,"scaleFactor":2,"colorSpace":"YnBsaXN0","size":[1470,956]}}"#

    @Test func decodesTheDesktopAcquire() throws {
        let request = try #require(WallpaperRequestDecoding.creationRequest(from: Data(Self.desktopAcquire.utf8)))
        #expect(request.configuration == Data(#"{"video":"spike"}"#.utf8))
        #expect(request.isPreview == false)
        #expect(request.presentationMode == .default)
        #expect(request.activityState == .active)
        #expect(request.systemAppearance == .dark)
        #expect(request.destination.size == CGSize(width: 1470, height: 956))
        #expect(request.destination.scaleFactor == 2)
        #expect(request.destination.directDisplayID == 1)
    }

    @Test func previewHasNoConfiguration() throws {
        let request = try #require(WallpaperRequestDecoding.creationRequest(from: Data(Self.previewAcquire.utf8)))
        #expect(request.isPreview)
        #expect(request.configuration == nil)
    }

    @Test func decodesTheLockUpdate() throws {
        let update = try #require(WallpaperRequestDecoding.updateRequest(from: Data(Self.lockUpdate.utf8)))
        #expect(update.presentationMode == .locked)
        #expect(update.activityState == .active)
    }

    @Test func keepsUnknownCasesInsteadOfFailing() throws {
        let json = #"{"presentationMode":{"standby":{}},"activityState":{"dozing":{}},"systemAppearance":{"sepia":{}}}"#
        let update = try #require(WallpaperRequestDecoding.updateRequest(from: Data(json.utf8)))
        #expect(update.presentationMode == .unknown("standby"))
        #expect(update.activityState == .unknown("dozing"))
        #expect(update.systemAppearance == .unknown("sepia"))
    }

    @Test func acceptsBareStringCases() throws {
        let update = try #require(WallpaperRequestDecoding.updateRequest(from: Data(#"{"presentationMode":"idle","activityState":"suspended"}"#.utf8)))
        #expect(update.presentationMode == .idle)
        #expect(update.activityState == .suspended)
    }

    @Test func missingFieldsFallBackToSafeDefaults() throws {
        let request = try #require(WallpaperRequestDecoding.creationRequest(from: Data("{}".utf8)))
        #expect(request.presentationMode == .default)
        #expect(request.activityState == .active)
        #expect(request.destination.pixelSize == nil)
    }

    @Test func rejectsNonObjects() {
        #expect(WallpaperRequestDecoding.creationRequest(from: Data("[]".utf8)) == nil)
        #expect(WallpaperRequestDecoding.updateRequest(from: Data("not json".utf8)) == nil)
    }

    @Test func pixelSizeAppliesTheScale() {
        let destination = WallpaperDestination(size: CGSize(width: 1470, height: 956), scaleFactor: 2)
        #expect(destination.pixelSize?.width == 2940)
        #expect(destination.pixelSize?.height == 1912)
    }

    @Test func readsTheWallpaperID() {
        #expect(WallpaperRequestDecoding.wallpaperID(from: Data(#"{"id":"38716569-AB9E-4619-A66B-DB0322393B4E"}"#.utf8)) == "38716569-AB9E-4619-A66B-DB0322393B4E")
        #expect(WallpaperRequestDecoding.wallpaperID(from: Data(#"{"id":""}"#.utf8)) == nil)
    }
}

@Suite struct DestinationSafetyTests {
    @Test func absurdSizesAreClampedNotTrapped() {
        let huge = WallpaperDestination(size: CGSize(width: 1e300, height: 1e300), scaleFactor: 1e300)
        #expect(huge.pixelSize?.width == WallpaperDestination.maxPixelSide)
        #expect(huge.pixelSize?.height == WallpaperDestination.maxPixelSide)
    }

    @Test func nonFiniteValuesAreRejectedOrIgnored() {
        #expect(WallpaperDestination(size: CGSize(width: CGFloat.nan, height: 900)).pixelSize == nil)
        #expect(WallpaperDestination(size: CGSize(width: CGFloat.infinity, height: 900)).pixelSize == nil)
        let badScale = WallpaperDestination(size: CGSize(width: 100, height: 50), scaleFactor: Double.nan)
        #expect(badScale.pixelSize?.width == 100)
    }

    @Test func zeroOrNegativeSizesHaveNoPixels() {
        #expect(WallpaperDestination(size: CGSize(width: 0, height: 900)).pixelSize == nil)
        #expect(WallpaperDestination(size: CGSize(width: -5, height: 900)).pixelSize == nil)
    }
}
