// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import KinoraKit
import Testing
@testable import KinoraMedia

/// The copy of the photo a Living Photo keeps so it can be made again.
@Suite struct LivingPhotoSourceCopyTests {
    @Test func keepsASmallerUprightCopyAndLeavesThePhotoAlone() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try SyntheticPhoto.figure(width: 5000, height: 3000, in: folder)
        let before = SHA256.hash(data: try Data(contentsOf: photo))
        let work = folder.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let copy = try LivingPhotoGenerator.keepSource(of: photo, in: work)
        #expect(copy.deletingLastPathComponent().standardizedFileURL == work.standardizedFileURL)
        let source = try #require(CGImageSourceCreateWithURL(copy as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) == LivingPhotoSource.maxSide)
        #expect(abs(Double(width) / Double(height) - 5000.0 / 3000.0) < 0.01)
        #expect(SHA256.hash(data: try Data(contentsOf: photo)) == before)

        // A Living Photo made from the copy has the shape the display asks for.
        let display = CGSize(width: 1440, height: 900)
        let renderer = try LivingPhotoRenderer(photo: copy, output: LivingPhotoSource.loopSize(for: display), motion: .gentle)
        #expect(renderer.plan.output == LivingPhotoSource.loopSize(for: display))
    }

    @Test func refusesWhatIsNotAPhoto() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = folder.appendingPathComponent("note.jpg")
        try Data("not a photo".utf8).write(to: text)
        #expect(throws: LivingPhotoError.unreadablePhoto) { try LivingPhotoGenerator.keepSource(of: text, in: folder) }
    }
}
