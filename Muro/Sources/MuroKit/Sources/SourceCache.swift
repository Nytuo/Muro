import Foundation

/// Remembers what a source's browse pages said, so opening Explore twice does
/// not ask the site twice.
///
/// These are public web pages Muro does not control and does not want to lean
/// on. What they hold changes at most daily, so a page read this morning is
/// still right this afternoon. Results are kept in memory for the session and
/// on disk under Caches, where they survive a relaunch and where macOS is free
/// to throw them away.
public enum SourceCache {
    public static let lifetime: TimeInterval = 24 * 3600
    static let capBytes: Int64 = 8 * 1024 * 1024

    private struct Entry: Codable {
        var storedAt: Date
        var results: [StoredResult]
    }

    private struct StoredResult: Codable {
        var source: String
        var key: String
        var title: String
        var thumbnail: URL
        var category: String?
    }

    private static let lock = NSLock()
    private static var memory: [String: Entry] = [:]

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muro/Sources", isDirectory: true)
    }

    public static func key(source: WallpaperSource, scope: String, page: Int) -> String {
        "\(source.rawValue)|\(scope.lowercased())|\(page)"
    }

    public static func read(_ key: String, maximumAge: TimeInterval = lifetime) -> [SourceResult]? {
        guard let entry = entry(for: key),
              Date().timeIntervalSince(entry.storedAt) < maximumAge
        else { return nil }
        return entry.results.compactMap(restore)
    }

    public static func readStale(_ key: String) -> [SourceResult]? {
        entry(for: key).map { $0.results.compactMap(restore) }
    }

    public static func write(_ results: [SourceResult], for key: String) {
        let entry = Entry(storedAt: Date(), results: results.map(store))
        lock.lock()
        memory[key] = entry
        lock.unlock()
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: key), options: .atomic)
        prune()
    }

    public static func clear() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }

    public static func sizeOnDisk() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - Plumbing

    private static func entry(for key: String) -> Entry? {
        lock.lock()
        let remembered = memory[key]
        lock.unlock()
        if let remembered { return remembered }
        guard let data = try? Data(contentsOf: fileURL(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data)
        else { return nil }
        lock.lock()
        memory[key] = entry
        lock.unlock()
        return entry
    }

    private static func fileURL(for key: String) -> URL {
        let safe = key.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "|" || scalar == "-" || scalar == "_"
                ? String(scalar)
                : String(format: "%%%02X", scalar.value)
        }.joined()
        return directory.appendingPathComponent("\(String(safe.prefix(180))).json")
    }

    private static func store(_ result: SourceResult) -> StoredResult {
        StoredResult(
            source: result.source.rawValue, key: result.key, title: result.title,
            thumbnail: result.thumbnail, category: result.category
        )
    }

    private static func restore(_ stored: StoredResult) -> SourceResult? {
        guard let source = WallpaperSource(rawValue: stored.source) else { return nil }
        return SourceResult(
            source: source, key: stored.key, title: stored.title,
            thumbnail: stored.thumbnail, category: stored.category
        )
    }

    private static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var entries = files.compactMap { url -> (url: URL, date: Date, size: Int64)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > capBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > capBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
