import CSceneEngine
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a downloaded Wallpaper Engine item into a library entry.
///
/// Two kinds of item play on a Mac. A **Video** item is an ordinary video
/// file, and it goes through the same importer as a video dropped on the
/// Library, so it gets the same master, thumbnail and preview. A **Scene**
/// item is packed into `scene.pkg`, and the scene engine translates it: image
/// layers, the effect chain, particles and parallax. Web and application
/// items run code Muro does not host, and are refused with a reason.
public enum WorkshopImporter {
    public struct Result {
        public let entry: WallpaperEntry
        public let skipped: [String]
    }

    public enum ImportError: LocalizedError {
        case notAWorkshopItem
        case unsupportedType(String)
        case missingVideo
        case needsFFmpeg
        case conversionFailed
        case sceneFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notAWorkshopItem:
                return "The download has no project.json, so it is not a Wallpaper Engine item Muro can read."
            case .unsupportedType(let type):
                return "This is a Wallpaper Engine \(type) wallpaper. Muro plays Video and Scene wallpapers only."
            case .missingVideo:
                return "The video this wallpaper names is not in the download."
            case .needsFFmpeg:
                return "This wallpaper is a WebM video, which macOS cannot play. Install ffmpeg (brew install ffmpeg) and download it again."
            case .conversionFailed:
                return "The WebM video could not be converted."
            case .sceneFailed(let reason):
                return "The scene could not be translated. \(reason)"
            }
        }
    }

    struct Project: Decodable {
        var title: String?
        var type: String?
        var file: String?
        var preview: String?
    }

    /// Imports the item at `item`, which is consumed: moved into the library
    /// for a scene, removed after copying for a video.
    public static func importItem(at item: URL, publishedFileID: String, root: URL) throws -> Result {
        let projectURL = item.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL),
              let project = try? JSONDecoder().decode(Project.self, from: data)
        else { throw ImportError.notAWorkshopItem }

        let origin = "\(WallpaperSource.workshop.rawValue):\(publishedFileID)"
        let title = project.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Workshop \(publishedFileID)"

        switch project.type?.lowercased() {
        case "video":
            let entry = try importVideoItem(item: item, project: project, title: title, origin: origin, root: root)
            try? FileManager.default.removeItem(at: item)
            return Result(entry: entry, skipped: [])
        case "scene":
            return try importSceneItem(item: item, project: project, title: title, origin: origin, root: root)
        case let other:
            throw ImportError.unsupportedType(other.map { $0.capitalized } ?? "unknown")
        }
    }

    /// Translates a scene again from the Workshop item kept beside it.
    ///
    /// The scene engine keeps improving, and a scene translated by an older
    /// version stays exactly as it was translated. The downloaded item is still
    /// there under `Scenes/<id>/item`, so nothing has to be downloaded again.
    ///
    /// The entry keeps its id, so playlists, automations and assignments
    /// pointing at it are untouched.
    @discardableResult
    public static func reimport(entry: WallpaperEntry, root: URL) throws -> Result {
        guard let sceneRelative = entry.scene else { throw ImportError.notAWorkshopItem }
        let sceneDirectory = root.appendingPathComponent(sceneRelative, isDirectory: true)
        let itemDirectory = sceneDirectory.appendingPathComponent("item", isDirectory: true)
        guard FileManager.default.fileExists(atPath: itemDirectory.appendingPathComponent("project.json").path)
        else { throw ImportError.notAWorkshopItem }

        let response = try translate(
            item: itemDirectory,
            scene: sceneDirectory,
            cache: sceneDirectory.appendingPathComponent("transcoded", isDirectory: true)
        )
        guard response["ok"] as? Bool == true else {
            throw ImportError.sceneFailed(response["error"] as? String ?? "")
        }

        var updated = entry
        updated.width = Int((response["canvas_width"] as? NSNumber)?.doubleValue ?? Double(entry.width))
        updated.height = Int((response["canvas_height"] as? NSNumber)?.doubleValue ?? Double(entry.height))
        updated.sizeBytes = folderSize(sceneDirectory)
        updated.hasAudio = SceneDescription.read(directory: sceneDirectory)?.audio.isEmpty == false
        let id = entry.id
        let fields = updated
        try LibraryWriter.update(root: root) { manifest in
            guard let row = manifest.wallpapers.firstIndex(where: { $0.id == id }) else { return }
            manifest.wallpapers[row].width = fields.width
            manifest.wallpapers[row].height = fields.height
            manifest.wallpapers[row].sizeBytes = fields.sizeBytes
            manifest.wallpapers[row].hasAudio = fields.hasAudio
        }
        return Result(entry: updated, skipped: response["skipped"] as? [String] ?? [])
    }

    // MARK: - Video items

    private static func importVideoItem(
        item: URL, project: Project, title: String, origin: String, root: URL
    ) throws -> WallpaperEntry {
        guard let file = project.file, isInside(item, item.appendingPathComponent(file)) else {
            throw ImportError.missingVideo
        }
        var source = item.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: source.path) else { throw ImportError.missingVideo }

        var converted: URL?
        if source.pathExtension.lowercased() == "webm" {
            converted = try convertWebM(source)
            source = converted!
        }
        defer { converted.map { try? FileManager.default.removeItem(at: $0) } }

        let category = WallpaperSource.workshop.libraryCategory
        do {
            return try importVideo(
                source: source, title: title, category: category, root: root,
                preserveOriginal: true, origin: origin
            )
        } catch {
            // A stream the passthrough export will not carry (an odd codec or
            // container) can still be re-encoded.
            return try importVideo(
                source: source, title: title, category: category, root: root,
                preserveOriginal: false, origin: origin
            )
        }
    }

    // MARK: - Scene items

    private static func importSceneItem(
        item: URL, project: Project, title: String, origin: String, root: URL
    ) throws -> Result {
        let manager = FileManager.default
        let id = UUID().uuidString.lowercased()
        let sceneRelative = "Scenes/\(id)"
        let sceneDirectory = root.appendingPathComponent(sceneRelative, isDirectory: true)
        let itemDirectory = sceneDirectory.appendingPathComponent("item", isDirectory: true)
        let thumbnailRelative = "Thumbnails/\(id).jpg"
        let thumbnail = root.appendingPathComponent(thumbnailRelative)

        try manager.createDirectory(at: sceneDirectory, withIntermediateDirectories: true)
        do {
            try manager.moveItem(at: item, to: itemDirectory)

            let response = try translate(
                item: itemDirectory,
                scene: sceneDirectory,
                cache: sceneDirectory.appendingPathComponent("transcoded", isDirectory: true)
            )
            guard response["ok"] as? Bool == true else {
                throw ImportError.sceneFailed(response["error"] as? String ?? "")
            }

            try? manager.createDirectory(
                at: root.appendingPathComponent("Thumbnails", isDirectory: true),
                withIntermediateDirectories: true
            )
            if let preview = project.preview, isInside(itemDirectory, itemDirectory.appendingPathComponent(preview)) {
                writeThumbnail(from: itemDirectory.appendingPathComponent(preview), to: thumbnail)
            }

            let entry = WallpaperEntry(
                id: id,
                title: title,
                category: WallpaperSource.workshop.libraryCategory,
                file: "\(sceneRelative)/scene.json",
                thumbnail: thumbnailRelative,
                width: Int((response["canvas_width"] as? NSNumber)?.doubleValue ?? 1920),
                height: Int((response["canvas_height"] as? NSNumber)?.doubleValue ?? 1080),
                fps: 30,
                duration: 0,
                sizeBytes: folderSize(sceneDirectory),
                scene: sceneRelative,
                origin: origin,
                hasAudio: SceneDescription.read(directory: sceneDirectory)?.audio.isEmpty == false
            )
            try LibraryWriter.update(root: root) { manifest in
                manifest.wallpapers.append(entry)
            }
            return Result(entry: entry, skipped: response["skipped"] as? [String] ?? [])
        } catch {
            try? manager.removeItem(at: sceneDirectory)
            try? manager.removeItem(at: thumbnail)
            throw error
        }
    }

    private static func translate(item: URL, scene: URL, cache: URL) throws -> [String: Any] {
        makeToolsReachable()
        guard let raw = item.path.withCString({ itemPath in
            scene.path.withCString { scenePath in
                cache.path.withCString { cachePath in
                    wer_we_import(itemPath, scenePath, cachePath)
                }
            }
        }) else { throw ImportError.sceneFailed("") }
        defer { wer_free_string(raw) }
        guard let data = String(cString: raw).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ImportError.sceneFailed("") }
        return json
    }

    // MARK: - Helpers

    /// A GIF or JPEG preview, first frame, as the library's JPEG thumbnail.
    static func writeThumbnail(from source: URL, to destination: URL) {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1280,
              ] as CFDictionary),
              let output = CGImageDestinationCreateWithURL(
                  destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              )
        else { return }
        CGImageDestinationAddImage(output, frame, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(output)
    }

    /// WebM to H.264 MP4 through ffmpeg
    private static func convertWebM(_ source: URL) throws -> URL {
        guard let ffmpeg = findFFmpeg() else { throw ImportError.needsFFmpeg }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("muro-\(UUID().uuidString).mp4")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-y", "-i", source.path, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw ImportError.conversionFailed
        }
        return output
    }

    /// Homebrew's folders, which an app started from Finder does not have on
    /// its PATH.
    private static let extraToolDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    public static func findFFmpeg() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) + extraToolDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("ffmpeg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The scene engine runs ffmpeg by name for a scene's WebM layers, so it
    /// needs Homebrew on this process's PATH to find it.
    private static func makeToolsReachable() {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let missing = extraToolDirectories.filter { !current.split(separator: ":").contains(Substring($0)) }
        guard !missing.isEmpty else { return }
        setenv("PATH", ([current] + missing).joined(separator: ":"), 1)
    }

    /// project.json names files relative to the item, and must not be able to
    /// name one outside it.
    private static func isInside(_ directory: URL, _ candidate: URL) -> Bool {
        candidate.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    private static func folderSize(_ directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
