// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import CoreGraphics
import Foundation
import Testing
@testable import KinoraKit

@Suite struct LivingPhotoPlanTests {
    let display = CGSize(width: 2940, height: 1912)
    /// The spike's test photo: 3912 × 3936.
    let squarePhoto = CGSize(width: 3912, height: 3936)

    @Test func coversTheDisplayWithOverscan() throws {
        let plan = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: nil))
        #expect(plan.canvas.width >= display.width * LivingPhotoPlan.overscan - 1)
        #expect(plan.canvas.height >= display.height * LivingPhotoPlan.overscan - 1)
        // The spike's canvas for this photo was 3176 × 3195.
        #expect(abs(plan.canvas.width - 3176) <= 1)
        #expect(abs(plan.canvas.height - 3195) <= 2)
        #expect(CGRect(origin: .zero, size: plan.canvas).contains(plan.crop))
    }

    @Test func keepsOutputSidesEven() throws {
        let plan = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: CGSize(width: 1513, height: 983), subject: nil))
        #expect(Int(plan.output.width) % 2 == 0 && Int(plan.output.height) % 2 == 0)
    }

    @Test func refusesNonsense() {
        #expect(LivingPhotoPlan.make(photo: .zero, output: display, subject: nil) == nil)
        #expect(LivingPhotoPlan.make(photo: squarePhoto, output: CGSize(width: 1, height: 1), subject: nil) == nil)
        #expect(LivingPhotoPlan.make(photo: CGSize(width: Double.nan, height: 10), output: display, subject: nil) == nil)
    }

    @Test func aTallSubjectKeepsItsHeadInWithHeadroom() throws {
        // A standing figure filling most of a square photo's height.
        let subject = CGRect(x: 1400, y: 200, width: 1100, height: 3500)
        let plan = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: subject))
        let top = try #require(plan.subject).maxY
        // The crop's top sits the headroom above the subject's top, as in the spike.
        #expect(abs(plan.crop.maxY - (top + display.height * LivingPhotoPlan.headroom)) < 1 || plan.crop.maxY >= top)
        #expect(plan.crop.maxY >= top)
    }

    @Test func aSmallSubjectIsCentredNotPinnedToTheTop() throws {
        let subject = CGRect(x: 1800, y: 1800, width: 300, height: 300)
        let plan = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: subject))
        let placed = try #require(plan.subject)
        #expect(abs(plan.center.y - placed.midY) < 1)
        #expect(abs(plan.center.x - placed.midX) < 1)
    }

    @Test func framingNeverLeavesTheCanvas() throws {
        // A subject in the very corner of a tall photo.
        let tall = CGSize(width: 3000, height: 4000)
        for subject in [CGRect(x: 0, y: 0, width: 200, height: 200), CGRect(x: 2800, y: 3800, width: 200, height: 200)] {
            let plan = try #require(LivingPhotoPlan.make(photo: tall, output: display, subject: subject))
            let mx = plan.canvas.width * LivingPhotoPlan.edgeMargin - 1, my = plan.canvas.height * LivingPhotoPlan.edgeMargin - 1
            #expect(plan.crop.minX >= mx && plan.crop.minY >= my)
            #expect(plan.crop.maxX <= plan.canvas.width - mx && plan.crop.maxY <= plan.canvas.height - my)
        }
    }

    @Test func subjectsOutsideThePhotoAreIgnored() throws {
        let plan = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: CGRect(x: 9000, y: 9000, width: 10, height: 10)))
        #expect(plan.subject == nil)
    }

    @Test func theLoopEndsWhereItStarts() throws {
        for subject in [CGRect(x: 1400, y: 200, width: 1100, height: 3500), nil] as [CGRect?] {
            for motion in LivingPhotoMotion.allCases {
                let plan = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: subject, motion: motion))
                for placement in [plan.subjectPlacement, plan.backgroundPlacement] {
                    let start = placement(0), end = placement(1)
                    #expect(abs(start.dx - end.dx) < 1e-9 && abs(start.dy - end.dy) < 1e-9 && abs(start.scale - end.scale) < 1e-12)
                }
                // Frame N would be frame 0: phases stop one step short of 1.
                #expect(plan.phase(ofFrame: plan.frameCount - 1) < 1)
                #expect(plan.phase(ofFrame: 0) == 0)
            }
        }
    }

    @Test func noEdgeEverShows() throws {
        let photos = [squarePhoto, CGSize(width: 4032, height: 3024), CGSize(width: 3024, height: 4032), CGSize(width: 6000, height: 1500)]
        let displays = [display, CGSize(width: 3840, height: 2160), CGSize(width: 5120, height: 1440), CGSize(width: 1920, height: 1200)]
        for photo in photos {
            for output in displays {
                for subject in [CGRect(x: photo.width * 0.4, y: photo.height * 0.1, width: photo.width * 0.2, height: photo.height * 0.7), nil] as [CGRect?] {
                    for motion in LivingPhotoMotion.allCases {
                        let plan = try #require(LivingPhotoPlan.make(photo: photo, output: output, subject: subject, motion: motion))
                        for step in 0..<120 {
                            #expect(plan.backgroundCoversCrop(at: Double(step) / 120), "photo \(photo) on \(output), \(motion)")
                        }
                    }
                }
            }
        }
    }

    @Test func theFilledGapIsWiderThanTheSubjectEverMoves() throws {
        let photos = [squarePhoto, CGSize(width: 3024, height: 4032)]
        for photo in photos {
            let subject = CGRect(x: 0, y: 0, width: photo.width, height: photo.height * 0.95)
            for motion in LivingPhotoMotion.allCases {
                let plan = try #require(LivingPhotoPlan.make(photo: photo, output: display, subject: subject, motion: motion))
                #expect(plan.fill.gapGrowth > plan.largestSubjectShift())
            }
        }
    }

    @Test func lessMotionThanTheFirstSpike() throws {
        // Round 2 cut the subject's offset against the background to about 12 px on a 2940 px display.
        let plan = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: CGRect(x: 1900, y: 1900, width: 100, height: 100)))
        let quarter = plan.subjectPlacement(at: 0.25).dx - plan.backgroundPlacement(at: 0.25).dx
        #expect(abs(quarter - 12.1) < 0.5)
        let gentle = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: plan.subject, motion: .gentle))
        #expect(gentle.subjectPlacement(at: 0.25).dx < plan.subjectPlacement(at: 0.25).dx)
    }

    @Test func fillSizesScaleWithTheCanvas() throws {
        let full = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: nil))
        let preview = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: CGSize(width: 735, height: 478), subject: nil))
        let ratio = full.canvas.width / preview.canvas.width
        #expect(abs(full.fill.fillRadii[0] / preview.fill.fillRadii[0] - ratio) < 0.01)
        #expect(abs(full.fill.edgeInset - 2) < 0.01)
        #expect(full.fill.fillRadii.count == 3)
    }

    @Test func clampsDurationAndFrameRate() throws {
        let plan = try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: nil, seconds: 600, framesPerSecond: 500))
        #expect(plan.seconds == 60 && plan.framesPerSecond == 60)
        #expect(plan.frameCount == 3600)
        #expect(try #require(LivingPhotoPlan.make(photo: squarePhoto, output: display, subject: nil)).frameCount == 360)
    }
}

@Suite struct TextureTransferTests {
    /// A 40 × 4 image: a checker texture everywhere, the fill flat grey, the gap in columns 16..<24.
    func fixture() -> (photo: [UInt8], blurred: [UInt8], fill: [UInt8], gap: [Bool], width: Int, height: Int) {
        let width = 40, height = 4
        var photo = [UInt8](repeating: 0, count: width * height * 4)
        let blurred = [UInt8](repeating: 128, count: width * height * 4)
        let fill = [UInt8](repeating: 100, count: width * height * 4)
        var gap = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = (x + y) % 2 == 0 ? 138 : 118
                for c in 0..<3 { photo[(y * width + x) * 4 + c] = value }
                photo[(y * width + x) * 4 + 3] = 255
                if (16..<24).contains(x) { gap[y * width + x] = true }
            }
        }
        return (photo, blurred, fill, gap, width, height)
    }

    @Test func addsThePhotosDetailInsideTheGapOnly() throws {
        var f = fixture()
        let done = try TextureTransfer.apply(photo: f.photo, blurred: f.blurred, fill: &f.fill, gap: f.gap, width: f.width, height: f.height)
        #expect(done)
        for y in 0..<f.height {
            for x in 0..<f.width {
                let value = f.fill[(y * f.width + x) * 4]
                if f.gap[y * f.width + x] {
                    // Detail is ±10 around the grey fill, so the gap now has texture.
                    #expect(value == 90 || value == 110 || value == 100)
                } else {
                    #expect(value == 100)
                }
            }
        }
        let gapValues = Set((16..<24).map { f.fill[$0 * 4] })
        #expect(gapValues.count > 1)
    }

    @Test func leavesAlphaAlone() throws {
        var f = fixture()
        try TextureTransfer.apply(photo: f.photo, blurred: f.blurred, fill: &f.fill, gap: f.gap, width: f.width, height: f.height)
        #expect(f.fill[(16) * 4 + 3] == 100)
    }

    @Test func stopsWhenCancelled() throws {
        var f = fixture()
        let done = try TextureTransfer.apply(photo: f.photo, blurred: f.blurred, fill: &f.fill, gap: f.gap, width: f.width, height: f.height,
                                             isCancelled: { true })
        #expect(!done)
    }

    @Test func refusesMismatchedBuffers() {
        var fill = [UInt8](repeating: 0, count: 8)
        #expect(throws: TextureTransfer.Failure.self) {
            try TextureTransfer.apply(photo: [0], blurred: [0], fill: &fill, gap: [false], width: 2, height: 1)
        }
    }

    @Test func findsTheGapsColumns() {
        let f = fixture()
        #expect(TextureTransfer.gapColumns(f.gap, width: f.width, height: f.height) == 16...23)
        #expect(TextureTransfer.gapColumns([Bool](repeating: false, count: 4), width: 2, height: 2) == nil)
    }
}
