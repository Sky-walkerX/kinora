// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation

/// Where the sun is in the sky, for the live-sky wallpaper. The NOAA solar position equations
/// (after Meeus), accurate to well under a degree, which is far more than a sky gradient needs.
public enum SunPosition {
    public struct Angles: Equatable, Sendable {
        /// Degrees above the horizon; negative below it.
        public var elevation: Double
        /// Degrees clockwise from north.
        public var azimuth: Double
    }

    /// The sun's position at `date` seen from `latitude` and `longitude` in degrees (east positive).
    public static func angles(at date: Date, latitude: Double, longitude: Double) -> Angles {
        let julianDay = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { r * 180 / .pi }
        func norm(_ d: Double) -> Double { let m = d.truncatingRemainder(dividingBy: 360); return m < 0 ? m + 360 : m }

        let meanLongitude = norm(280.46646 + t * (36_000.76983 + t * 0.0003032))
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let m = rad(meanAnomaly)
        let center = sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(2 * m) * (0.019993 - 0.000101 * t) + sin(3 * m) * 0.000289
        let trueLongitude = meanLongitude + center
        let omega = 125.04 - 1934.136 * t
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sin(rad(omega))
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(rad(omega))
        let declination = asin(sin(rad(obliquity)) * sin(rad(apparentLongitude)))

        let y = pow(tan(rad(obliquity / 2)), 2)
        let l0 = rad(meanLongitude)
        let equationOfTime = 4 * deg(y * sin(2 * l0) - 2 * eccentricity * sin(m) + 4 * eccentricity * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0) - 1.25 * eccentricity * eccentricity * sin(2 * m))

        let minutesUTC = (julianDay + 0.5 - floor(julianDay + 0.5)) * 1440
        let trueSolarTime = (minutesUTC + equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let lat = rad(latitude), ha = rad(hourAngle)
        let cosZenith = min(1, max(-1, sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(ha)))
        let zenith = acos(cosZenith)
        var azimuth: Double
        let denominator = cos(lat) * sin(zenith)
        if abs(denominator) > 1e-9 {
            let cosAzimuth = min(1, max(-1, (sin(lat) * cos(zenith) - sin(declination)) / denominator))
            let a = deg(acos(cosAzimuth))
            azimuth = hourAngle > 0 ? norm(a + 180) : norm(540 - a)
        } else {
            azimuth = latitude > 0 ? 180 : 0
        }
        return Angles(elevation: 90 - deg(zenith), azimuth: azimuth)
    }

    /// How much daylight there is, 0 at night to 1 in full day, easing through twilight
    /// (from 6° below the horizon to 6° above it).
    public static func daylight(elevation: Double) -> Double {
        let x = min(1, max(0, (elevation + 6) / 12))
        return x * x * (3 - 2 * x)
    }
}

/// Roughly where the Mac is, without asking for its location: the principal city of its time
/// zone, from the zone table macOS ships. Good enough for sunrise and sunset to within minutes.
public enum ApproximateLocation {
    public struct Coordinates: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// The zone tables, newest format first.
    public static let zoneTables = ["/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab"]

    /// The coordinates for `zone` from a zone table's text: lines of `country<TAB>±DDMM[SS]±DDDMM[SS]<TAB>Zone/Name`.
    public static func coordinates(forZone zone: String, in table: String) -> Coordinates? {
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[2] == zone else { continue }
            return parse(String(fields[1]))
        }
        return nil
    }

    /// ISO 6709 as the zone table writes it: `+513030-0000731` or `+4043-07400`.
    static func parse(_ text: String) -> Coordinates? {
        let scalars = Array(text)
        guard let split = scalars.indices.dropFirst().first(where: { scalars[$0] == "+" || scalars[$0] == "-" }) else { return nil }
        func value(_ part: ArraySlice<Character>, degreeDigits: Int) -> Double? {
            guard let sign = part.first, sign == "+" || sign == "-" else { return nil }
            let digits = String(part.dropFirst())
            guard digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4 else { return nil }
            let d = Double(digits.prefix(degreeDigits)) ?? 0
            let rest = digits.dropFirst(degreeDigits)
            let m = Double(rest.prefix(2)) ?? 0
            let s = rest.count > 2 ? Double(rest.dropFirst(2)) ?? 0 : 0
            let magnitude = d + m / 60 + s / 3600
            return sign == "-" ? -magnitude : magnitude
        }
        guard let lat = value(scalars[..<split], degreeDigits: 2), let lon = value(scalars[split...], degreeDigits: 3),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return Coordinates(latitude: lat, longitude: lon)
    }

    /// From the time zone's standard offset alone: its central meridian, at a mid-northern latitude.
    public static func fromOffset(_ zone: TimeZone, at date: Date = Date()) -> Coordinates {
        let standard = Double(zone.secondsFromGMT(for: date)) - zone.daylightSavingTimeOffset(for: date)
        return Coordinates(latitude: 40, longitude: max(-180, min(180, standard / 3600 * 15)))
    }

    /// The best guess for `zone`, reading macOS's zone table when it can.
    public static func current(_ zone: TimeZone = .current, readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Coordinates {
        for path in zoneTables {
            if let table = readFile(path), let found = coordinates(forZone: zone.identifier, in: table) { return found }
        }
        return fromOffset(zone)
    }
}
