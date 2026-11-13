// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

import Foundation
import Testing
@testable import KinoraKit

@Suite struct ForeignWallpaperTests {
    func lively(_ json: String) -> ForeignWallpaper.Wallpaper? {
        ForeignWallpaper.parse(Data(json.utf8), source: .lively, folderName: "folder")
    }

    func engine(_ json: String) -> ForeignWallpaper.Wallpaper? {
        ForeignWallpaper.parse(Data(json.utf8), source: .wallpaperEngine, folderName: "folder")
    }

    @Test func findsTheManifest() {
        #expect(ForeignWallpaper.manifest(in: ["LivelyInfo.json", "video.mp4"])?.source == .lively)
        #expect(ForeignWallpaper.manifest(in: ["project.json", "scene.pkg"])?.source == .wallpaperEngine)
        #expect(ForeignWallpaper.manifest(in: ["video.mp4"]) == nil)
    }

    @Test func readsALivelyVideo() throws {
        let w = try #require(lively(#"{"AppVersion":"2.0.0","Title":"Rain","Author":"Someone","License":"CC BY 4.0","Type":7,"FileName":"rain.mp4","IsAbsolutePath":false}"#))
        #expect(w.title == "Rain" && w.author == "Someone" && w.license == "CC BY 4.0")
        #expect(w.kind == .video(file: "rain.mp4"))
        #expect(try ForeignWallpaper.support(w).get() == "rain.mp4")
    }

    @Test func readsLivelyTypesByNumberOrName() throws {
        #expect(try #require(lively(#"{"Type":8,"FileName":"a.gif"}"#)).kind == .gif(file: "a.gif"))
        #expect(try #require(lively(#"{"Type":11,"FileName":"a.jpg"}"#)).kind == .picture(file: "a.jpg"))
        #expect(try #require(lively(#"{"Type":"Video","FileName":"a.mp4"}"#)).kind == .video(file: "a.mp4"))
        #expect(try #require(lively(#"{"Type":1,"FileName":"index.html"}"#)).kind == .web)
        #expect(try #require(lively(#"{"Type":5,"FileName":"game.exe"}"#)).kind == .program)
        #expect(try #require(lively(#"{"Type":10,"FileName":"https://example.com"}"#)).kind == .stream)
        #expect(try #require(lively(#"{"Type":99}"#)).kind == .unknown("unknown"))
        // Lively writes a byte-order mark on some files.
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(#"{"Title":"BOM","Type":7,"FileName":"v.mp4"}"#.utf8)
        #expect(ForeignWallpaper.parse(bom, source: .lively, folderName: "x")?.title == "BOM")
    }

    @Test func refusesFilesOutsideTheFolder() throws {
        #expect(try #require(lively(#"{"Type":7,"FileName":"C:\\Users\\me\\v.mp4","IsAbsolutePath":true}"#)).kind == .unknown("video"))
        #expect(try #require(lively(#"{"Type":7,"FileName":"v.mp4","IsAbsolutePath":true}"#)).kind == .unknown("absolute"))
        #expect(try #require(engine(#"{"type":"video","file":"../../secret.mp4"}"#)).kind == .unknown("video"))
        #expect(ForeignWallpaper.relativePath("media\\clip.mp4") == "media/clip.mp4")
        #expect(ForeignWallpaper.relativePath("/etc/passwd") == nil)
        #expect(ForeignWallpaper.relativePath("a/../b") == nil)
    }

    @Test func readsWallpaperEngineProjects() throws {
        let video = try #require(engine(#"{"title":"Neon City","type":"Video","file":"neon.mp4","preview":"preview.gif","workshopid":"123"}"#))
        #expect(video.title == "Neon City" && video.kind == .video(file: "neon.mp4"))
        #expect(try #require(engine(#"{"title":"S","type":"scene","file":"scene.json"}"#)).kind == .scene)
        #expect(try #require(engine(#"{"title":"W","type":"web","file":"index.html"}"#)).kind == .web)
        #expect(try #require(engine(#"{"type":"application","file":"x.exe"}"#)).title == "folder")
    }

    @Test func explainsWhatItCannotImport() throws {
        #expect(ForeignWallpaper.support(try #require(engine(#"{"type":"scene"}"#))) == .failure(.scene))
        #expect(ForeignWallpaper.support(try #require(engine(#"{"type":"video","file":"v.webm"}"#))) == .failure(.webm))
        #expect(ForeignWallpaper.support(try #require(lively(#"{"Type":0,"FileName":"a.exe"}"#))) == .failure(.program))
        for problem in [ForeignWallpaper.Unsupported.webm, .web, .scene, .program, .stream, .elsewhere, .unknown] {
            #expect(!problem.description.isEmpty)
        }
    }

    @Test func toleratesJunk() {
        #expect(lively("[]") == nil)
        #expect(lively("not json") == nil)
        #expect(ForeignWallpaper.parse(Data(count: ForeignWallpaper.manifestBytes + 1), source: .lively, folderName: "x") == nil)
    }
}
