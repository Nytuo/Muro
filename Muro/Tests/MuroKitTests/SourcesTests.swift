import AVFoundation
import XCTest
@testable import MuroKit

final class SourceParsingTests: XCTestCase {
    func testWorkshopTilesAreReadAndDeduplicated() {
        let html = """
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=3799142774" class="tK5agp5sRy8-"><img src="https://images.steamusercontent.com/ugc/954/4DE4/?ima=fit&amp;impolicy=Letterbox&amp;imw=288" alt="Rhine Lab · Interactive" loading="lazy" class=""/></a>
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=3799142774" class="tK5agp5sRy8-"><img src="https://images.steamusercontent.com/ugc/954/4DE4/?ima=fit&amp;impolicy=Letterbox&amp;imw=288" alt="Rhine Lab · Interactive" loading="lazy" class=""/></a>
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=3793439427" class="x"><img src="https://images.steamusercontent.com/ugc/x/thumb.jpg" alt="Miku &amp; Box" loading="lazy" class=""/></a>
        """
        let results = SourceBrowser.parseWorkshop(html)
        XCTAssertEqual(results.map(\.key), ["3799142774", "3793439427"])
        XCTAssertEqual(results[1].title, "Miku & Box")
        XCTAssertEqual(results[0].thumbnail.absoluteString, "https://images.steamusercontent.com/ugc/954/4DE4/?ima=fit&impolicy=Letterbox&imw=288")
        XCTAssertEqual(results[0].origin, "workshop:3799142774")
    }

    func testMotionBGsTilesAreRead() {
        let html = """
        <a title="Rick and Morty Stargazing live wallpaper" href=/rick-and-morty-stargazing> <figure><picture><source media="(-webkit-min-device-pixel-ratio: 1.5)" srcset=/i/c/546x308/media/9939/rick-and-morty-stargazing.3840x2160.jpg.webp type=image/webp><img alt="rick and morty stargazing live wallpaper" fetchpriority=high height=205 src=/i/c/364x205/media/9939/rick-and-morty-stargazing.3840x2160.jpg width=364></picture></figure></a>
        <a title="Itachi Uchiha in Front of the Red Moon animated wallpaper" href=/itachi> <figure><picture><img src=/i/c/364x205/media/9000/itachi.jpg></picture></figure></a>
        """
        let results = SourceBrowser.parseMotionBGs(html)
        XCTAssertEqual(results.map(\.key), ["9939", "9000"])
        XCTAssertEqual(results[0].title, "Rick and Morty Stargazing")
        XCTAssertEqual(results[0].thumbnail.absoluteString, "https://motionbgs.com/i/c/364x205/media/9939/rick-and-morty-stargazing.3840x2160.jpg")
        XCTAssertEqual(SourceBrowser.videoURL(for: results[0], quality: .uhd)?.absoluteString, "https://motionbgs.com/dl/4k/9939")
    }

    func testWallperTilesAreRead() {
        let html = """
        <article style="width:100%"><a class="WallpaperCard_cardMinimal__2i7gx" aria-label="Silver Surfer" href="/wallpaper/space/silver-surfer-8771267f-7e16-465d-a402-7b87e0e4b635"><div class="WallpaperCard_cardMinimalMedia__bvorO"><div class="VideoThumbnail_root__rqiBh"><div class="VideoThumbnail_skeleton__z_NQg " aria-hidden="true"></div><img alt="Silver Surfer - Live Wallpaper for Mac" decoding="async" data-nimg="fill" srcSet="/_next/image?url=https%3A%2F%2Fcdn.wallper.app%2Fpreviews%2F8771267f-7e16-465d-a402-7b87e0e4b635.png&amp;w=256&amp;q=75 256w"></div></div></a></article>
        """
        let results = SourceBrowser.parseWallper(html, category: "space")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].key, "8771267f-7e16-465d-a402-7b87e0e4b635")
        XCTAssertEqual(results[0].title, "Silver Surfer")
        XCTAssertEqual(results[0].thumbnail.absoluteString, "https://cdn.wallper.app/previews/8771267f-7e16-465d-a402-7b87e0e4b635.png")
        XCTAssertEqual(
            SourceBrowser.videoURL(for: results[0])?.absoluteString,
            "https://cdn.wallper.app/wallper-user-generated/8771267f-7e16-465d-a402-7b87e0e4b635.mp4"
        )
    }

    func testWallperCatalogueIsReadFromTheGalleryPage() {
        let html = #"""
        {\"initialWallpapers\":[{\"id\":\"0b7b0607-93c6-4784-a2c6-69d03f18e030\",\"age\":\"Minimalist\",\"author\":\"Red Eye\",\"duration\":11,\"likes\":23,\"name\":\"The Look Of Love\",\"resolution\":\"3840x2160\",\"sizeMB\":25.97,\"status\":\"Success\",\"previewImageKey\":\"0b7b0607-93c6-4784-a2c6-69d03f18e030.png\",\"fileKey\":\"0b7b0607-93c6-4784-a2c6-69d03f18e030.mp4\"},{\"id\":\"de242078-e306-4bb8-8f92-785e716593a0\",\"age\":\"Games\",\"author\":\"S\",\"duration\":26,\"likes\":10,\"name\":\"Sword Dance\",\"resolution\":\"2560x1440\",\"sizeMB\":64.27,\"status\":\"Success\",\"previewImageKey\":\"de242078-e306-4bb8-8f92-785e716593a0.png\"}]}
        """#
        let results = SourceBrowser.parseWallperCatalogue(html)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "The Look Of Love")
        XCTAssertEqual(results[0].category, "minimalist")
        XCTAssertEqual(results[0].key, "0b7b0607-93c6-4784-a2c6-69d03f18e030")
        XCTAssertEqual(
            results[0].thumbnail.absoluteString,
            "https://cdn.wallper.app/previews/0b7b0607-93c6-4784-a2c6-69d03f18e030.png"
        )
        XCTAssertEqual(results[1].title, "Sword Dance")
        XCTAssertEqual(
            SourceBrowser.videoURL(for: results[1])?.absoluteString,
            "https://cdn.wallper.app/wallper-user-generated/de242078-e306-4bb8-8f92-785e716593a0.mp4"
        )
    }

    func testWorkshopLinksAndIDs() {
        XCTAssertEqual(SourceBrowser.workshopID(from: " 2853719148 "), "2853719148")
        XCTAssertEqual(
            SourceBrowser.workshopID(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=2853719148&searchtext="),
            "2853719148"
        )
        XCTAssertNil(SourceBrowser.workshopID(from: "anime rain"))
        XCTAssertNil(SourceBrowser.workshopID(from: "https://evil.example/?id=1"))
    }

    func testAKeyThatIsNotTheSitesShapeGetsNoDownloadURL() {
        let bad = SourceResult(source: .wallper, key: "../../etc", title: "x", thumbnail: URL(string: "https://a.b")!)
        XCTAssertNil(SourceBrowser.videoURL(for: bad))
        let workshop = SourceResult(source: .workshop, key: "1", title: "x", thumbnail: URL(string: "https://a.b")!)
        XCTAssertNil(SourceBrowser.videoURL(for: workshop))
    }
}

final class SourceCacheTests: XCTestCase {
    private let scope = "test-\(UUID().uuidString)"

    override func tearDown() {
        SourceCache.clear()
        super.tearDown()
    }

    private func result(_ title: String) -> SourceResult {
        SourceResult(
            source: .motionBGs, key: "1", title: title,
            thumbnail: URL(string: "https://motionbgs.com/t.jpg")!
        )
    }

    func testAPageComesBackAsItWentIn() {
        let key = SourceCache.key(source: .motionBGs, scope: scope, page: 1)
        XCTAssertNil(SourceCache.read(key))
        SourceCache.write([result("Neon")], for: key)
        XCTAssertEqual(SourceCache.read(key)?.first?.title, "Neon")
        XCTAssertEqual(SourceCache.read(key)?.first?.source, .motionBGs)
    }

    func testAnOldPageIsNotServedButIsStillThereToFallBackOn() {
        let key = SourceCache.key(source: .motionBGs, scope: scope, page: 2)
        SourceCache.write([result("Yesterday")], for: key)
        XCTAssertNil(SourceCache.read(key, maximumAge: 0))
        XCTAssertEqual(SourceCache.readStale(key)?.first?.title, "Yesterday")
    }

    func testPagesAndSearchesAreKeptApart() {
        let first = SourceCache.key(source: .motionBGs, scope: "cars", page: 1)
        let second = SourceCache.key(source: .motionBGs, scope: "cars", page: 2)
        let other = SourceCache.key(source: .wallper, scope: "cars", page: 1)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, other)
        SourceCache.write([result("Slash")], for: SourceCache.key(source: .motionBGs, scope: "a/b c", page: 1))
        XCTAssertEqual(
            SourceCache.read(SourceCache.key(source: .motionBGs, scope: "a/b c", page: 1))?.first?.title,
            "Slash"
        )
    }

    func testClearingEmptiesIt() {
        let key = SourceCache.key(source: .motionBGs, scope: scope, page: 3)
        SourceCache.write([result("Gone")], for: key)
        SourceCache.clear()
        XCTAssertNil(SourceCache.readStale(key))
    }
}

final class WorkshopDownloadOutputTests: XCTestCase {
    func testPromptsAreRecognisedOnTheLastLine() {
        XCTAssertEqual(WorkshopDownload.prompt(in: ["Connecting", "Enter account password for \"me\": "]), .password)
        XCTAssertEqual(WorkshopDownload.prompt(in: ["Please enter your 2 factor auth code from your authenticator app: "]), .code)
        XCTAssertEqual(WorkshopDownload.prompt(in: ["Please enter the auth code sent to the email at a***@b.c: ", ""]), .code)
        XCTAssertNil(WorkshopDownload.prompt(in: ["Got depot key", " 12.00% project.json"]))
    }

    func testTheAccountAQRScanSignedInToIsRead() {
        let text = "Success! Next time you can login with -username somebody -remember-password instead of -qr.\n"
        XCTAssertEqual(WorkshopDownload.usernameAfterQRLogin(in: text), "somebody")
        XCTAssertNil(WorkshopDownload.usernameAfterQRLogin(in: "Logging in"))
    }

    func testTheTextQRCodeBecomesSquareModules() {
        let row = String(repeating: "██  ", count: 11)
        let lines = ["Use the Steam Mobile App to sign in with this QR code:"]
            + Array(repeating: row, count: 22)
            + ["Waiting…"]
        let grid = WorkshopDownload.qrCode(in: lines)
        XCTAssertEqual(grid?.count, 22)
        XCTAssertEqual(grid?.first?.count, 22)
        XCTAssertEqual(grid?.first?.prefix(4), [true, false, true, false])
        XCTAssertNil(WorkshopDownload.qrCode(in: ["sign in with this QR code:", "", "done"]))
    }
}

final class WallpaperAudioTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muro-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeVideoWithSound() throws -> URL {
        guard let ffmpeg = WorkshopImporter.findFFmpeg() else {
            throw XCTSkip("ffmpeg is not installed on this Mac")
        }
        let output = root.appendingPathComponent("source.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y",
            "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest",
            output.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("ffmpeg could not make the fixture") }
        return output
    }

    private func hasAudio(_ url: URL) -> Bool {
        var found = false
        let done = DispatchSemaphore(value: 0)
        AVURLAsset(url: url).loadTracks(withMediaType: .audio) { tracks, _ in
            found = !(tracks ?? []).isEmpty
            done.signal()
        }
        done.wait()
        return found
    }

    func testTheOriginalQualityImportKeepsTheSound() throws {
        let source = try makeVideoWithSound()
        let entry = try importVideo(
            source: source, title: "Sine", category: "Test", root: root, preserveOriginal: true
        )
        XCTAssertEqual(entry.hasAudio, true)
        XCTAssertTrue(hasAudio(root.appendingPathComponent(entry.file)))
    }

    func testTheHEVCImportKeepsTheSound() throws {
        let source = try makeVideoWithSound()
        let entry = try importVideo(
            source: source, title: "Sine", category: "Test", root: root, preserveOriginal: false
        )
        XCTAssertEqual(entry.hasAudio, true)
        XCTAssertTrue(hasAudio(root.appendingPathComponent(entry.file)))
    }

    func testAVideoWithNoSoundSaysSo() throws {
        guard let ffmpeg = WorkshopImporter.findFFmpeg() else { throw XCTSkip("ffmpeg is not installed") }
        let silent = root.appendingPathComponent("silent.mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y", "-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=30",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", silent.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let entry = try importVideo(
            source: silent, title: "Silent", category: "Test", root: root, preserveOriginal: true
        )
        XCTAssertEqual(entry.hasAudio, false)
    }

    func testTheVolumeSettingSurvivesItsOldName() throws {
        var config = EngineConfig()
        config.sceneVolume = 0.5
        XCTAssertEqual(config.volume, 0.5, "a config written when this was Scene Sound still applies")
        config.wallpaperVolume = 0.25
        XCTAssertEqual(config.volume, 0.25, "the new key wins")
        XCTAssertEqual(EngineConfig().volume, 0, "silent unless asked")
    }
}

final class CatalogSafetyTests: XCTestCase {
    private func entry(id: String, video: String = "https://cdn.example/v.mov") -> CatalogEntry {
        CatalogEntry(
            id: id, title: "t", category: "c", width: 1, height: 1, fps: 30, duration: 1, sizeBytes: 1,
            video: URL(string: video)!, thumbnail: URL(string: "https://cdn.example/t.jpg")!
        )
    }

    func testPublishedIDsPass() {
        XCTAssertTrue(entry(id: "c0b0484f-80b9-40f3-bf02-03cd0886ba82").isSafe)
    }

    func testIDsThatWouldLeaveTheLibraryAreDropped() {
        XCTAssertFalse(entry(id: "../../Library/LaunchAgents/x").isSafe)
        XCTAssertFalse(entry(id: "..").isSafe)
        XCTAssertFalse(entry(id: "a/b").isSafe)
        XCTAssertFalse(entry(id: "").isSafe)
    }

    func testLocalFileURLsAreDropped() {
        XCTAssertFalse(entry(id: "ok", video: "file:///etc/passwd").isSafe)
    }
}

final class SceneEntryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muro-scene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAManifestWrittenBeforeScenesStillDecodes() throws {
        let json = """
        {"wallpapers":[{"id":"a","title":"A","category":"C","file":"Masters/a.mov","thumbnail":"Thumbnails/a.jpg",
        "width":1920,"height":1080,"fps":30,"duration":10,"sizeBytes":5,"liked":false,"dateAdded":"2026-01-01T00:00:00Z"}]}
        """
        try json.data(using: .utf8)!.write(to: LibraryManifest.manifestURL(root: root))
        let manifest = try XCTUnwrap(LibraryManifest.loadIfPresent(root: root))
        XCTAssertFalse(manifest.wallpapers[0].isScene)
        XCTAssertNil(manifest.wallpapers[0].origin)
    }

    func testDeletingASceneTakesItsWholeFolder() throws {
        let folder = root.appendingPathComponent("Scenes/s/item", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("Scenes/s/scene.json"))
        let entry = WallpaperEntry(
            id: "s", title: "S", category: "Workshop", file: "Scenes/s/scene.json", thumbnail: "Thumbnails/s.jpg",
            width: 1, height: 1, fps: 30, duration: 0, sizeBytes: 0, scene: "Scenes/s", origin: "workshop:1"
        )
        try LibraryWriter.update(root: root) { $0.wallpapers.append(entry) }
        try LibraryWriter.delete(ids: ["s"], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Scenes/s").path))
    }

    func testADeleteNeverReachesOutsideTheLibrary() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("muro-outside-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let entry = WallpaperEntry(
            id: "x", title: "X", category: "C", file: "../\(outside.lastPathComponent)", thumbnail: "Thumbnails/x.jpg",
            width: 1, height: 1, fps: 30, duration: 0, sizeBytes: 0
        )
        try LibraryWriter.update(root: root) { $0.wallpapers.append(entry) }
        try LibraryWriter.delete(ids: ["x"], root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testWebItemsAreRefusedWithAReason() throws {
        let item = root.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data(#"{"title":"Site","type":"web","file":"index.html"}"#.utf8)
            .write(to: item.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try WorkshopImporter.importItem(at: item, publishedFileID: "1", root: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Web"))
        }
    }

    func testARealWorkshopSceneImports() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Library/Application Support/macpaperengine/workshop_downloads")
        guard let source = ["2853719148", "2802222492"].map({ downloads.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scene.pkg").path) })
        else { throw XCTSkip("no downloaded Workshop scene on this Mac") }

        let item = root.appendingPathComponent("download", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: item)
        let result = try WorkshopImporter.importItem(at: item, publishedFileID: source.lastPathComponent, root: root)

        XCTAssertTrue(result.entry.isScene)
        XCTAssertEqual(result.entry.origin, "workshop:\(source.lastPathComponent)")
        let scene = root.appendingPathComponent(try XCTUnwrap(result.entry.scene))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scene.appendingPathComponent("scene.json").path))
        let description = try XCTUnwrap(SceneDescription.read(directory: scene))
        XCTAssertTrue(description.isLayered)
        XCTAssertGreaterThan(description.canvasWidth, 0)
        let surface = SceneSurface(sceneDirectory: scene, size: CGSize(width: 640, height: 360), scale: 1)
        XCTAssertNotNil(surface)
        surface?.invalidate()

        if let audio = description.audio.first {
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.url.path))
            let sounding = try XCTUnwrap(SceneSurface(
                sceneDirectory: scene, size: CGSize(width: 320, height: 180), scale: 1, volume: 0.5
            ))
            XCTAssertTrue(sounding.hasAudio)
            sounding.invalidate()
        }
        XCTAssertEqual(LibraryManifest.loadIfPresent(root: root)?.wallpapers.first?.id, result.entry.id)
    }
}
