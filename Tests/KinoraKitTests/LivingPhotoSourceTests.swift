// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation
import Testing
@testable import KinoraKit

@Suite struct LivingPhotoSourceTests {
    func index(_ livingPhoto: String) -> Data {
        Data(#"""
        {"version": 1, "items": [{"id": "\#(UUID().uuidString)", "name": "Beach", "kind": "livingPhoto", "media": "a.mov",
          "thumbnail": "a.png", "addedAt": "2026-11-21T00:00:00Z", "livingPhoto": \#(livingPhoto)}]}
        """#.utf8)
    }

    @Test func roundTripsWithItsItem() throws {
        var item = LibraryItem(name: "Beach", kind: .livingPhoto, media: "a.mov", thumbnail: "a.png", addedAt: Date(timeIntervalSince1970: 0))
        item.livingPhoto = LivingPhotoSource(photo: "a-photo.heic", motion: "lively", width: 2940, height: 1912)
        let decoded = try #require(LibraryIndex.decode(try LibraryIndex(items: [item]).encoded()))
        #expect(decoded.items.first?.livingPhoto == item.livingPhoto)
        #expect(decoded.items.first?.livingPhoto?.motionStrength == .lively)
    }

    @Test func aDamagedSourceCostsOnlyTheRemake() throws {
        // Paths, the loop's own file and junk keep the item but drop what it was made from.
        for bad in [#"{"photo": "../../secret.heic", "motion": "subtle", "width": 1, "height": 1}"#,
                    #"{"photo": "a.mov", "motion": "subtle", "width": 1, "height": 1}"#,
                    #"{"motion": 7}"#, "42", #""photo""#] {
            let decoded = try #require(LibraryIndex.decode(index(bad)), "\(bad)")
            #expect(decoded.items.count == 1, "\(bad)")
            #expect(decoded.items.first?.livingPhoto == nil, "\(bad)")
        }
        // A motion this version doesn't know is kept, and treated as the default.
        let future = try #require(LibraryIndex.decode(index(#"{"photo": "p.heic", "motion": "wild", "width": 10, "height": 8}"#)))
        #expect(future.items.first?.livingPhoto?.motion == "wild")
        #expect(future.items.first?.livingPhoto?.motionStrength == .subtle)
    }

    @Test func knowsWhenADisplayNeedsANewLoop() {
        let display = CGSize(width: 2940, height: 1912)
        let made = LivingPhotoSource.loopSize(for: display)
        let source = LivingPhotoSource(photo: "p.heic", motion: "subtle", width: Int(made.width), height: Int(made.height))
        #expect(!source.needsRemaking(for: display))
        #expect(source.needsRemaking(for: CGSize(width: 5120, height: 2880)))
        #expect(source.needsRemaking(for: CGSize(width: 1920, height: 1080)))
    }
}
