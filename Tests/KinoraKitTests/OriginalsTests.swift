// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

@Suite struct SunPositionTests {
    func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func londonAtMidsummerNoon() {
        // Solar noon in London on the June solstice is about 12:02 UTC, elevation about 62°, due south.
        let sun = SunPosition.angles(at: utc(2026, 6, 21, 12, 2), latitude: 51.5074, longitude: -0.1278)
        #expect(abs(sun.elevation - 61.9) < 0.5)
        #expect(abs(sun.azimuth - 180) < 3)
    }

    @Test func belowTheHorizonAtMidnight() {
        let sun = SunPosition.angles(at: utc(2026, 12, 21, 0), latitude: 51.5074, longitude: -0.1278)
        #expect(sun.elevation < -40)
    }

    @Test func risesInTheEastAndSetsInTheWest() {
        // New York, March equinox: morning sun in the east, evening sun in the west.
        let morning = SunPosition.angles(at: utc(2026, 3, 20, 12), latitude: 40.71, longitude: -74.0)
        let evening = SunPosition.angles(at: utc(2026, 3, 20, 22), latitude: 40.71, longitude: -74.0)
        #expect(morning.azimuth > 90 && morning.azimuth < 180)
        #expect(evening.azimuth > 180 && evening.azimuth < 270)
        #expect(morning.elevation > 0 && evening.elevation > 0)
    }

    @Test func overheadAtTheEquatorOnTheEquinox() {
        let sun = SunPosition.angles(at: utc(2026, 3, 20, 12, 7), latitude: 0, longitude: 0)
        #expect(sun.elevation > 88)
    }

    @Test func daylightEasesThroughTwilight() {
        #expect(SunPosition.daylight(elevation: -20) == 0)
        #expect(SunPosition.daylight(elevation: 30) == 1)
        #expect(abs(SunPosition.daylight(elevation: 0) - 0.5) < 1e-9)
        #expect(SunPosition.daylight(elevation: -3) < SunPosition.daylight(elevation: 3))
    }
}

@Suite struct ApproximateLocationTests {
    let table = """
    # comment
    GB\t+513030-0000731\tEurope/London
    US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)
    AU\t-3352+15113\tAustralia/Sydney\tNew South Wales (most areas)
    XX\tgarbage\tBroken/Zone
    """

    @Test func readsTheZoneTable() throws {
        let london = try #require(ApproximateLocation.coordinates(forZone: "Europe/London", in: table))
        #expect(abs(london.latitude - 51.508) < 0.01 && abs(london.longitude + 0.125) < 0.01)
        let sydney = try #require(ApproximateLocation.coordinates(forZone: "Australia/Sydney", in: table))
        #expect(abs(sydney.latitude + 33.867) < 0.01 && abs(sydney.longitude - 151.217) < 0.01)
        #expect(ApproximateLocation.coordinates(forZone: "Broken/Zone", in: table) == nil)
        #expect(ApproximateLocation.coordinates(forZone: "Nowhere/Else", in: table) == nil)
    }

    @Test func fallsBackToTheTimeZonesMeridian() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let guess = ApproximateLocation.current(tokyo) { _ in nil }
        #expect(guess.longitude == 135)
        #expect(guess.latitude == 40)
    }
}

@Suite struct KinoraOriginalsTests {
    @Test func identifiersAreUniqueAndStable() {
        let ids = KinoraOriginals.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(KinoraOriginals.all.map(\.slug)).count == ids.count)
        #expect(KinoraOriginals.original(UUID(uuidString: "6B1F7E2A-4C3D-4E8A-9A51-0D2C7B3E5A01"))?.slug == "liveSky")
        #expect(KinoraOriginals.original(UUID()) == nil)
        #expect(KinoraOriginals.all.allSatisfy { $0.palette.count == 3 })
    }

    @Test func frameRateFollowsTheOriginalTheSettingAndTheBattery() throws {
        let aurora = try #require(KinoraOriginals.all.first { $0.slug == "aurora" })
        var settings = PlaybackSettings()
        #expect(KinoraOriginals.framesPerSecond(for: aurora, settings: settings, cap: nil) == 30)
        #expect(KinoraOriginals.framesPerSecond(for: aurora, settings: settings, cap: 24) == 24)
        settings.generativeFrameRate = 15
        #expect(KinoraOriginals.framesPerSecond(for: aurora, settings: settings, cap: nil) == 15)
    }

    @Test func drawsAtAFractionOfTheDisplay() throws {
        let tide = try #require(KinoraOriginals.all.first { $0.slug == "tide" })
        let size = KinoraOriginals.drawableSize(for: tide, width: 2940, height: 1912)
        #expect(size.width == 735 && size.height == 478)
    }
}

@Suite struct SkySampleTests {
    @Test func theSunCrossesTheViewAsItDoesOutside() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func at(_ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: hour))! }
        let london = ApproximateLocation.Coordinates(latitude: 51.5, longitude: 0)
        let sydney = ApproximateLocation.Coordinates(latitude: -33.9, longitude: 151.2)
        // Morning is left of centre, evening right of it.
        #expect(SkySample.at(at(8), location: london).offset < 0)
        #expect(SkySample.at(at(16), location: london).offset > 0)
        // Looking north from Sydney (UTC+11 in March), the morning sun is to the right.
        #expect(SkySample.at(at(23), location: sydney).offset > 0)
        #expect(SkySample.at(at(5), location: sydney).offset < 0)
        #expect(SkySample.at(at(12), location: london).daylight == 1)
    }
}

@Suite struct SettingsGroupsTests {
    @Test func listsEachGroupWithTilesInOrder() throws {
        let tile = SettingsTile(id: "a", name: "A", thumbnail: URL(fileURLWithPath: "/tmp/a.png"), configuration: ChoiceConfiguration(wallpaper: UUID()))
        let data = SettingsViewModels.json(groups: [
            SettingsGroup(id: "one", name: "Kinora", tiles: [tile]),
            SettingsGroup(id: "empty", name: "Nothing", tiles: []),
            SettingsGroup(id: "two", name: "Kinora Originals", tiles: [tile, tile]),
        ])
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let desktop = try #require(root["desktop"] as? [String: Any])
        let groups = try #require(desktop["groups"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(groups.map { $0["localizedName"] as? String } == ["Kinora", "Kinora Originals"])
        #expect(groups.map { $0["sortOrder"] as? Int } == [0, 1])
        #expect((groups[1]["items"] as? [Any])?.count == 2)
    }
}
