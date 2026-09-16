import Foundation

/// SteamRE's DepotDownloader, the Steam client Muro uses to fetch Workshop
/// items.
///
/// Valve's own `steamcmd` has no working macOS build (its last one is 32-bit),
/// and Wallpaper Engine does not allow anonymous Workshop downloads, so this
/// is the route that works: a native macOS build of an open source Steam
/// client, signed in with the user's own account. That account has to own
/// Wallpaper Engine; Steam gates the depot keys on it, and Muro does not try
/// to get around that.
///
/// It is not bundled. It is fetched from its GitHub releases only when the
/// user asks for Workshop downloads to be set up, and it runs as a separate
/// process. DepotDownloader is GPL-2.0 licensed.
public enum DepotDownloader {
    public static let release = "DepotDownloader_3.4.0"

    public static func directory(root: URL) -> URL {
        root.appendingPathComponent("Tools/DepotDownloader", isDirectory: true)
    }

    public static func executable(root: URL) -> URL {
        directory(root: root).appendingPathComponent("DepotDownloader")
    }

    public static func isInstalled(root: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: executable(root: root).path)
    }

    private static var assetName: String {
        #if arch(arm64)
        return "DepotDownloader-macos-arm64.zip"
        #else
        return "DepotDownloader-macos-x64.zip"
        #endif
    }

    public enum InstallError: LocalizedError {
        case downloadFailed
        case unpackFailed

        public var errorDescription: String? {
            switch self {
            case .downloadFailed: return "DepotDownloader could not be downloaded from GitHub."
            case .unpackFailed: return "DepotDownloader was downloaded but could not be unpacked."
            }
        }
    }

    public static func install(root: URL) async throws {
        let url = URL(string: "https://github.com/SteamRE/DepotDownloader/releases/download/\(release)/\(assetName)")!
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError.downloadFailed
        }
        let destination = directory(root: root)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, destination.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        let binary = executable(root: root)
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw InstallError.unpackFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        _ = binary.withUnsafeFileSystemRepresentation { path in
            path.map { removexattr($0, "com.apple.quarantine", 0) } ?? 0
        }
    }
}

/// One Workshop item being fetched by DepotDownloader.
///
/// The login is interactive. DepotDownloader prints a password prompt, a Steam
/// Guard prompt, or a QR code to scan with the Steam app, and waits on stdin.
/// This class surfaces that output and forwards what the user types. A
/// password only ever passes through `send(_:)` on its way to the child's
/// stdin: it is never an argument (visible to `ps`), never stored, never
/// logged.
///
/// `-remember-password` makes DepotDownloader keep a refresh token in its own
/// store, so after one successful sign-in the same username downloads without
/// asking again.
public final class WorkshopDownload: @unchecked Sendable {
    public enum Login: Equatable {
        case username(String)
        case qrCode
    }

    public enum Prompt: Equatable {
        case password
        case code
    }

    public let publishedFileID: String
    public let destination: URL

    public var onOutput: (() -> Void)?
    public var onExit: ((Bool) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let lock = NSLock()
    private var buffer = ""

    public init(executable: URL, publishedFileID: String, destination: URL, login: Login) throws {
        self.publishedFileID = publishedFileID
        self.destination = destination
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        process.executableURL = executable
        var arguments = [
            "-app", "\(SourceBrowser.wallpaperEngineAppID)",
            "-pubfile", publishedFileID,
            "-dir", destination.path,
        ]
        switch login {
        case .username(let name):
            arguments += ["-username", name, "-remember-password"]
        case .qrCode:
            arguments += ["-qr", "-remember-password"]
        }
        process.arguments = arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()

        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer += String(decoding: data, as: UTF8.self)
            if self.buffer.utf8.count > 512_000 { self.buffer = String(self.buffer.suffix(256_000)) }
            self.lock.unlock()
            DispatchQueue.main.async { self.onOutput?() }
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            let ok = process.terminationReason == .exit && process.terminationStatus == 0
            DispatchQueue.main.async { self?.onExit?(ok) }
        }
        try process.run()
    }

    public var output: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public var lines: [String] {
        output.components(separatedBy: .newlines)
    }

    public var isRunning: Bool { process.isRunning }

    public func send(_ text: String) {
        guard process.isRunning, let data = (text + "\n").data(using: .utf8) else { return }
        input.fileHandleForWriting.write(data)
    }

    public func cancel() {
        guard process.isRunning else { return }
        process.terminate()
    }

    // MARK: - Reading the output

    public static func prompt(in lines: [String]) -> Prompt? {
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?.lowercased()
        else { return nil }
        if last.contains("password") { return .password }
        if last.contains("steam guard") || last.contains("auth code") || last.contains("two-factor")
            || last.contains("2fa") || last.contains("two factor") {
            return .code
        }
        return nil
    }

    public static func usernameAfterQRLogin(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"Next time you can login with -username (\S+) -remember-password"#
        ), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// The QR code DepotDownloader draws as text, two characters per module,
    /// turned into real modules.
    public static func qrCode(in lines: [String]) -> [[Bool]]? {
        guard let start = lines.lastIndex(where: { $0.lowercased().contains("sign in with this qr code") })
        else { return nil }
        var rows: [String] = []
        for line in lines[(start + 1)...] {
            guard line.allSatisfy({ $0 == "█" || $0 == " " || $0 == "▀" || $0 == "▄" }) else { break }
            rows.append(line)
        }
        guard rows.count >= 15 else { return nil }
        let columns = (rows.map(\.count).max() ?? 0) / 2
        guard columns > 0 else { return nil }
        return rows.map { row in
            let characters = Array(row)
            return (0..<columns).map { column in
                let index = column * 2
                return index < characters.count && characters[index] != " "
            }
        }
    }
}
