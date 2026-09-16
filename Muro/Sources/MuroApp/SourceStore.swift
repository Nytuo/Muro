import SwiftUI
import MuroKit

/// Downloads from the sources outside Muro's own catalog: MotionBGs and
/// Wallper as plain videos, and the Steam Workshop through DepotDownloader.
@MainActor
final class SourceStore: ObservableObject {
    static let shared = SourceStore()

    private let root = LibraryManifest.defaultRoot()
    private let defaults = UserDefaults.standard

    /// Downloads in flight, by origin. 0…1 while fetching; 1 while importing.
    @Published private(set) var downloads: [String: Double] = [:]
    /// The one alert this store shows.
    @Published var errorMessage: String?
    /// A finished import worth a sentence: a scene with parts left out.
    @Published var notice: String?

    // MARK: - Workshop account

    @Published private(set) var depotInstalled = false
    @Published private(set) var installingDepot = false

    /// Only the account name is kept. DepotDownloader holds its own refresh
    /// token after the first sign in; Muro never sees the password again.
    @Published var workshopUsername: String {
        didSet { defaults.set(workshopUsername, forKey: "workshopUsername") }
    }
    @Published var workshopUsesQR: Bool {
        didSet { defaults.set(workshopUsesQR, forKey: "workshopUsesQR") }
    }

    var workshopReady: Bool {
        depotInstalled && (workshopUsesQR || !workshopUsername.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - Workshop session

    struct WorkshopSession: Identifiable {
        enum Phase: Equatable {
            case running
            case importing
            case done(String)
            case failed(String)
        }

        let id: String
        let title: String
        var lines: [String] = []
        var prompt: WorkshopDownload.Prompt?
        var qrCode: [[Bool]]?
        var progress: Double?
        var phase: Phase = .running

        var isActive: Bool { phase == .running || phase == .importing }
    }

    @Published private(set) var workshop: WorkshopSession?
    private var process: WorkshopDownload?
    private var answeredLineCount = 0

    private init() {
        workshopUsername = defaults.string(forKey: "workshopUsername") ?? ""
        workshopUsesQR = defaults.bool(forKey: "workshopUsesQR")
        refreshDepotState()
        try? FileManager.default.removeItem(at: workshopStaging)
    }

    private var workshopStaging: URL {
        root.appendingPathComponent("Workshop", isDirectory: true)
    }

    // MARK: - Library lookups

    /// The downloaded wallpaper a browse result has already become.
    func libraryItem(for result: SourceResult) -> WallpaperItem? {
        let store = AppStore.shared
        guard let entry = store.manifest.wallpapers.first(where: { $0.origin == result.origin }) else {
            return nil
        }
        return store.item(id: entry.id)
    }

    // MARK: - Direct downloads

    func download(_ result: SourceResult, quality: MotionBGsQuality = .hd) {
        let origin = result.origin
        guard downloads[origin] == nil, libraryItem(for: result) == nil,
              let url = SourceBrowser.videoURL(for: result, quality: quality)
        else { return }
        downloads[origin] = 0
        let root = self.root
        let title = result.title
        let category = result.source.libraryCategory
        Task.detached(priority: .utility) {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("muro-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try await fetchMaster(from: url, to: temp) { progress in
                    Task { @MainActor in SourceStore.shared.downloads[origin] = progress }
                }
                await MainActor.run { SourceStore.shared.downloads[origin] = 1 }
                do {
                    _ = try importVideo(
                        source: temp, title: title, category: category, root: root,
                        preserveOriginal: true, origin: origin
                    )
                } catch {
                    _ = try importVideo(
                        source: temp, title: title, category: category, root: root,
                        preserveOriginal: false, origin: origin
                    )
                }
                await SourceStore.shared.finishDownload(origin: origin, title: title, error: nil)
            } catch {
                await SourceStore.shared.finishDownload(origin: origin, title: title, error: error)
            }
        }
    }

    private func finishDownload(origin: String, title: String, error: Error?) {
        downloads[origin] = nil
        AppStore.shared.reloadFromDisk()
        AppStore.shared.recomputeSize()
        if let error {
            let reason = error is URLError
                ? "Check that you are online, then try again."
                : importFailureReason(error)
            errorMessage = "\(title) could not be downloaded. \(reason)"
        }
    }

    // MARK: - DepotDownloader

    func refreshDepotState() {
        depotInstalled = DepotDownloader.isInstalled(root: root)
    }

    func installDepot() {
        guard !installingDepot else { return }
        installingDepot = true
        let root = self.root
        Task {
            do {
                try await DepotDownloader.install(root: root)
            } catch {
                errorMessage = error.localizedDescription
            }
            installingDepot = false
            refreshDepotState()
        }
    }

    var stockAssetsFolder: URL {
        root.appendingPathComponent("WEAssets", isDirectory: true)
    }

    func revealStockAssets() {
        let materials = stockAssetsFolder.appendingPathComponent("materials", isDirectory: true)
        try? FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([materials])
    }

    // MARK: - Workshop downloads

    func downloadWorkshop(id: String, title: String) {
        guard workshop?.isActive != true else {
            errorMessage = "A Workshop download is already running. Wait for it to finish, or cancel it."
            return
        }
        guard depotInstalled else {
            errorMessage = "Set up Workshop downloads first. Explore's Workshop tab and Settings both have the button."
            return
        }
        guard workshopReady else {
            errorMessage = "Type the Steam account that owns Wallpaper Engine, or choose to sign in with a QR code."
            return
        }
        if let existing = AppStore.shared.manifest.wallpapers.first(where: { $0.origin == "workshop:\(id)" }) {
            if let item = AppStore.shared.item(id: existing.id) { AppStore.shared.openPreview(item) }
            return
        }

        let destination = workshopStaging.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        let login: WorkshopDownload.Login = workshopUsesQR
            ? .qrCode
            : .username(workshopUsername.trimmingCharacters(in: .whitespaces))
        do {
            let download = try WorkshopDownload(
                executable: DepotDownloader.executable(root: root),
                publishedFileID: id,
                destination: destination,
                login: login
            )
            download.onOutput = { [weak self] in self?.refreshWorkshop() }
            download.onExit = { [weak self] ok in self?.workshopExited(ok: ok) }
            process = download
            answeredLineCount = 0
            workshop = WorkshopSession(id: id, title: title)
            downloads["workshop:\(id)"] = 0
        } catch {
            errorMessage = "DepotDownloader could not be started. \(error.localizedDescription)"
        }
    }

    func answerWorkshopPrompt(_ text: String) {
        guard let process else { return }
        process.send(text)
        answeredLineCount = process.lines.count
        workshop?.prompt = nil
    }

    func cancelWorkshop() {
        process?.onExit = nil
        process?.cancel()
        if let id = workshop?.id {
            downloads["workshop:\(id)"] = nil
            try? FileManager.default.removeItem(at: workshopStaging.appendingPathComponent(id))
        }
        process = nil
        workshop = nil
    }

    func closeWorkshop() {
        if workshop?.phase == .running {
            cancelWorkshop()
        } else if workshop?.phase != .importing {
            workshop = nil
        }
    }

    func forgetWorkshopAccount() {
        workshopUsername = ""
        workshopUsesQR = false
    }

    private func refreshWorkshop() {
        guard let process, workshop?.phase == .running else { return }
        let lines = process.lines
        workshop?.lines = Array(lines.suffix(400))
        workshop?.qrCode = WorkshopDownload.qrCode(in: lines)
        workshop?.prompt = lines.count > answeredLineCount ? WorkshopDownload.prompt(in: lines) : nil
        if let percent = Self.lastPercent(in: lines) {
            workshop?.progress = percent
            downloads["workshop:\(process.publishedFileID)"] = percent
        }
    }

    private func workshopExited(ok: Bool) {
        guard let process, var session = workshop else { return }
        refreshWorkshop()
        let output = process.output
        self.process = nil
        session.prompt = nil
        session.qrCode = nil
        let origin = "workshop:\(session.id)"

        guard ok else {
            downloads[origin] = nil
            session.phase = .failed(Self.failureReason(in: output))
            workshop = session
            try? FileManager.default.removeItem(at: process.destination)
            return
        }

        if workshopUsesQR, let name = WorkshopDownload.usernameAfterQRLogin(in: output) {
            workshopUsername = name
            workshopUsesQR = false
        }

        session.phase = .importing
        workshop = session
        downloads[origin] = 1
        let root = self.root
        let item = process.destination
        let id = session.id
        Task.detached(priority: .userInitiated) {
            do {
                let result = try WorkshopImporter.importItem(at: item, publishedFileID: id, root: root)
                await SourceStore.shared.workshopImported(origin: origin, result: result)
            } catch {
                try? FileManager.default.removeItem(at: item)
                await SourceStore.shared.workshopImportFailed(origin: origin, error: error)
            }
        }
    }

    private func workshopImported(origin: String, result: WorkshopImporter.Result) {
        downloads[origin] = nil
        AppStore.shared.reloadFromDisk()
        AppStore.shared.recomputeSize()
        var message = "\(result.entry.title) is in your Library."
        if !result.skipped.isEmpty {
            message += " " + Self.skippedSummary(result.skipped)
        }
        workshop?.phase = .done(message)
    }

    private func workshopImportFailed(origin: String, error: Error) {
        downloads[origin] = nil
        workshop?.phase = .failed(error.localizedDescription)
    }

    /// Translates a scene again with the current engine, from the Workshop
    /// item kept beside it. Nothing is downloaded, and the wallpaper keeps its
    /// place in playlists and on whatever display is showing it.
    func reimportScene(_ item: WallpaperItem) {
        guard let entry = item.local, entry.isScene, downloads[entry.id] == nil else { return }
        downloads[entry.id] = 1
        let root = self.root
        Task.detached(priority: .userInitiated) {
            do {
                let result = try WorkshopImporter.reimport(entry: entry, root: root)
                await MainActor.run {
                    SourceStore.shared.downloads[entry.id] = nil
                    AppStore.shared.reloadFromDisk()
                    AppStore.shared.recomputeSize()
                    SourceStore.shared.notice = result.skipped.isEmpty
                        ? "\(result.entry.title) was translated again with the current scene engine."
                        : "\(result.entry.title) was translated again. " + Self.skippedSummary(result.skipped)
                }
            } catch {
                await MainActor.run {
                    SourceStore.shared.downloads[entry.id] = nil
                    SourceStore.shared.errorMessage = "\(entry.title) could not be translated again. \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Local Wallpaper Engine folders

    func importWorkshopFolder(_ folder: URL) {
        let root = self.root
        let staging = workshopStaging.appendingPathComponent("local-\(UUID().uuidString)", isDirectory: true)
        let key = folder.lastPathComponent
        AppStore.shared.importStatus = "Importing…"
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: staging.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: folder, to: staging)
                let result = try WorkshopImporter.importItem(at: staging, publishedFileID: key, root: root)
                await MainActor.run {
                    AppStore.shared.importStatus = nil
                    AppStore.shared.reloadFromDisk()
                    AppStore.shared.recomputeSize()
                    if !result.skipped.isEmpty {
                        SourceStore.shared.notice = "\(result.entry.title) was imported. Some parts of the scene cannot be drawn yet and were left out."
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: staging)
                await MainActor.run {
                    AppStore.shared.importStatus = nil
                    AppStore.shared.importError = "\(folder.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    static func skippedSummary(_ skipped: [String], limit: Int = 2) -> String {
        guard !skipped.isEmpty else { return "" }
        let shown = skipped.prefix(limit).map { reason -> String in
            reason.count > 140 ? String(reason.prefix(140)) + "…" : reason
        }
        let count = skipped.count
        let heading = count == 1
            ? "One part of the scene cannot be drawn:"
            : "\(count) parts of the scene cannot be drawn:"
        let rest = count > shown.count ? " (and \(count - shown.count) more)" : ""
        return heading + " " + shown.joined(separator: "; ") + rest
    }

    // MARK: - Reading DepotDownloader

    /// DepotDownloader prints " 12.34% path/to/file" per file it writes.
    static func lastPercent(in lines: [String]) -> Double? {
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let percentIndex = trimmed.firstIndex(of: "%"),
                  let value = Double(trimmed[..<percentIndex]), (0...100).contains(value)
            else { continue }
            return value / 100
        }
        return nil
    }

    static func failureReason(in output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("is not available from this account") || lower.contains("no subscription") {
            return "This Steam account does not own Wallpaper Engine. Workshop items can only be downloaded by an account that owns it."
        }
        if lower.contains("invalidpassword") || lower.contains("invalid password") {
            return "Steam did not accept the password."
        }
        if lower.contains("rate limit") || lower.contains("ratelimit") {
            return "Steam is limiting sign in attempts. Wait a few minutes and try again."
        }
        return "DepotDownloader stopped before the item was downloaded. The log above has the details."
    }
}

/// The alerts `SourceStore` raises, hung on the root view next to the rest.
struct SourceAlerts: ViewModifier {
    @ObservedObject private var sources = SourceStore.shared

    func body(content: Content) -> some View {
        content
            .alert("Couldn’t download wallpaper", isPresented: Binding(
                get: { sources.errorMessage != nil },
                set: { if !$0 { sources.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { sources.errorMessage = nil }
            } message: {
                Text(sources.errorMessage ?? "")
            }
            .alert("Imported", isPresented: Binding(
                get: { sources.notice != nil },
                set: { if !$0 { sources.notice = nil } }
            )) {
                Button("OK", role: .cancel) { sources.notice = nil }
            } message: {
                Text(sources.notice ?? "")
            }
            .sheet(item: Binding(
                get: { sources.workshop },
                set: { if $0 == nil { sources.closeWorkshop() } }
            )) { _ in
                WorkshopDownloadSheet()
            }
    }
}
