// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// The sun as the live sky shows it.
public struct SkySample: Equatable, Sendable {
    public var elevation: Double
    public var azimuth: Double
    public var daylight: Double
    /// Degrees between the sun and the middle of the view, which faces the equator.
    public var offset: Double

    public init(elevation: Double, azimuth: Double, daylight: Double, offset: Double) {
        self.elevation = elevation
        self.azimuth = azimuth
        self.daylight = daylight
        self.offset = offset
    }

    /// The sky at `date` over `location`, looking towards the equator as someone there would to
    /// see the sun: south in the northern hemisphere, where it crosses from left to right, and
    /// north in the southern, where it crosses from right to left.
    public static func at(_ date: Date, location: ApproximateLocation.Coordinates) -> SkySample {
        let sun = SunPosition.angles(at: date, latitude: location.latitude, longitude: location.longitude)
        let facing = location.latitude >= 0 ? 180.0 : 0.0
        var offset = (sun.azimuth - facing).truncatingRemainder(dividingBy: 360)
        if offset > 180 { offset -= 360 }
        if offset < -180 { offset += 360 }
        return SkySample(elevation: sun.elevation, azimuth: sun.azimuth, daylight: SunPosition.daylight(elevation: sun.elevation), offset: offset)
    }

    /// A pleasant mid-afternoon, for previews that must not depend on the clock.
    public static let afternoon = SkySample(elevation: 32, azimuth: 215, daylight: 1, offset: 35)
}
