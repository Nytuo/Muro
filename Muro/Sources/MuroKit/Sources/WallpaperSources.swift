import Foundation

/// The places outside Muro's own catalog that Explore can download from.
///
/// None of them has an API, so each is read the way a browser reads it: the
/// public HTML page, matched on its structure rather than on class names that
/// change with every deploy of the site. That is an accepted fragility, and it
/// is why every parser here has a test built from a real captured page.
public enum WallpaperSource: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Wallpaper Engine's Steam Workshop. Downloading needs a Steam account
    /// that owns Wallpaper Engine, through DepotDownloader.
    case workshop
    /// motionbgs.com, direct MP4 downloads in HD or 4K.
    case motionBGs
    /// wallper.app, direct MP4 downloads.
    case wallper

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .workshop: return "Steam Workshop"
        case .motionBGs: return "MotionBGs"
        case .wallper: return "Wallper"
        }
    }

    public var searchable: Bool { true }

    /// Wallper is the only one browsed by category.
    public var hasCategories: Bool { self == .wallper }

    /// The library category a wallpaper from here is filed under.
    public var libraryCategory: String {
        switch self {
        case .workshop: return "Workshop"
        case .motionBGs: return "MotionBGs"
        case .wallper: return "Wallper"
        }
    }
}

/// One thing a source offers to download.
public struct SourceResult: Identifiable, Hashable, Sendable {
    public var source: WallpaperSource
    /// The site's own key: a Workshop published file id, a MotionBGs media
    /// id, or a Wallper UUID.
    public var key: String
    public var title: String
    public var thumbnail: URL
    public var category: String?
    public var origin: String { "\(source.rawValue):\(key)" }
    public var id: String { origin }

    public init(source: WallpaperSource, key: String, title: String, thumbnail: URL, category: String? = nil) {
        self.source = source
        self.key = key
        self.title = title
        self.thumbnail = thumbnail
        self.category = category
    }
}

public enum SourceError: LocalizedError, Equatable {
    case unreachable
    case server(status: Int)

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return "The site could not be reached. Check that you are online, then try again."
        case .server(let status):
            return "The site answered with an error (\(status)). Try again in a minute."
        }
    }
}

/// What to narrow a Workshop browse to. Wallpaper Engine tags every item with
/// its type, and only Video and Scene items can play.
public enum WorkshopItemType: String, CaseIterable, Identifiable {
    case any = "All"
    case scene = "Scene"
    case video = "Video"

    public var id: String { rawValue }
}

public enum MotionBGsQuality: String, CaseIterable, Identifiable {
    case hd, uhd = "4k"

    public var id: String { rawValue }
    public var label: String { self == .hd ? "HD" : "4K" }
}

public enum SourceBrowser {
    static let userAgent = "Mozilla/5.0 (Macintosh; Mac OS X) Muro"

    /// Wallpaper Engine's Steam app id.
    public static let wallpaperEngineAppID = 431960

    /// Every category in wallper.app's own sitemap. There is no endpoint that
    /// lists them, so this is the fixed list the site publishes.
    public static let wallperCategories = [
        "anime", "animals", "blue", "cars", "city", "cyberpunk", "dark", "fantasy",
        "forest", "games", "graphics", "japan", "light", "minimalist", "movies",
        "nature", "ocean", "orange", "other", "people", "pixelart", "rain", "scifi",
        "space", "sunset", "winter",
    ]

    // MARK: - Browsing

    public static func workshop(
        query: String, type: WorkshopItemType, page: Int, refresh: Bool = false
    ) async throws -> [SourceResult] {
        try await cached(source: .workshop, scope: "\(type.rawValue)|\(query)", page: page, refresh: refresh) {
            try await fetchWorkshop(query: query, type: type, page: page)
        }
    }

    private static func fetchWorkshop(query: String, type: WorkshopItemType, page: Int) async throws -> [SourceResult] {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var items = [
            URLQueryItem(name: "appid", value: "\(wallpaperEngineAppID)"),
            URLQueryItem(name: "section", value: "readytouseitems"),
            URLQueryItem(name: "p", value: "\(max(1, page))"),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            items.append(URLQueryItem(name: "browsesort", value: "trend"))
        } else {
            items.append(URLQueryItem(name: "searchtext", value: trimmed))
            items.append(URLQueryItem(name: "browsesort", value: "textsearch"))
        }
        if type != .any {
            items.append(URLQueryItem(name: "requiredtags[]", value: type.rawValue))
        }
        components.queryItems = items
        return parseWorkshop(try await fetchHTML(components.url!))
    }

    public static func motionBGs(query: String, page: Int, refresh: Bool = false) async throws -> [SourceResult] {
        try await cached(source: .motionBGs, scope: query, page: page, refresh: refresh) {
            try await fetchMotionBGs(query: query, page: page)
        }
    }

    private static func fetchMotionBGs(query: String, page: Int) async throws -> [SourceResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = max(1, page)
        let url: URL
        if trimmed.isEmpty {
            url = URL(string: page == 1 ? "https://motionbgs.com/" : "https://motionbgs.com/\(page)/")!
        } else {
            var components = URLComponents(string: "https://motionbgs.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
                + (page > 1 ? [URLQueryItem(name: "p", value: "\(page)")] : [])
            url = components.url!
        }
        return parseMotionBGs(try await fetchHTML(url))
    }

    /// Browsing a category reads that category's own pages. Searching reads
    /// the gallery's catalogue instead and filters it here — the site has no
    /// search request to make, and its own search box does the same thing.
    public static func wallper(
        query: String = "", category: String, page: Int, refresh: Bool = false
    ) async throws -> [SourceResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else {
            return try await searchWallper(trimmed, page: page, refresh: refresh)
        }
        guard wallperCategories.contains(category) else { return [] }
        return try await cached(source: .wallper, scope: "category:\(category)", page: page, refresh: refresh) {
            let page = max(1, page)
            let base = "https://www.wallper.app/wallpapers/\(category)"
            let url = URL(string: page == 1 ? base : "\(base)?page=\(page)")!
            return parseWallper(try await fetchHTML(url), category: category)
        }
    }

    public static func wallperCatalogue(refresh: Bool = false) async throws -> [SourceResult] {
        try await cached(source: .wallper, scope: "catalogue", page: 1, refresh: refresh) {
            parseWallperCatalogue(try await fetchHTML(URL(string: "https://www.wallper.app/wallpapers")!))
        }
    }
    static let wallperPageSize = 24

    private static func searchWallper(_ query: String, page: Int, refresh: Bool) async throws -> [SourceResult] {
        let catalogue = try await wallperCatalogue(refresh: refresh && page <= 1)
        let matches = catalogue.filter { result in
            result.title.localizedCaseInsensitiveContains(query)
                || (result.category?.localizedCaseInsensitiveContains(query) ?? false)
        }
        let start = max(0, page - 1) * wallperPageSize
        guard start < matches.count else { return [] }
        return Array(matches[start..<min(start + wallperPageSize, matches.count)])
    }

    // MARK: - Direct downloads

    /// The MP4 behind a MotionBGs or Wallper result. Nil for the Workshop,
    /// which downloads through DepotDownloader instead.
    public static func videoURL(for result: SourceResult, quality: MotionBGsQuality = .hd) -> URL? {
        switch result.source {
        case .workshop:
            return nil
        case .motionBGs:
            guard result.key.allSatisfy(\.isNumber) else { return nil }
            return URL(string: "https://motionbgs.com/dl/\(quality.rawValue)/\(result.key)")
        case .wallper:
            guard isUUID(result.key) else { return nil }
            return URL(string: "https://cdn.wallper.app/wallper-user-generated/\(result.key).mp4")
        }
    }

    /// A Workshop link or a bare published file id.
    public static func workshopID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count <= 20, trimmed.allSatisfy(\.isNumber) { return trimmed }
        guard let components = URLComponents(string: trimmed),
              components.host?.hasSuffix("steamcommunity.com") == true,
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, id.count <= 20, id.allSatisfy(\.isNumber)
        else { return nil }
        return id
    }

    // MARK: - Parsing

    static func parseWorkshop(_ html: String) -> [SourceResult] {
        let pattern = #"sharedfiles/filedetails/\?id=(\d+)"\s+class="[^"]*"><img src="([^"]+)" alt="([^"]*)""#
        var seen = Set<String>()
        return matches(pattern, in: html).compactMap { groups in
            guard seen.insert(groups[1]).inserted,
                  let thumbnail = URL(string: unescapeHTML(groups[2]))
            else { return nil }
            return SourceResult(
                source: .workshop, key: groups[1], title: unescapeHTML(groups[3]), thumbnail: thumbnail
            )
        }
    }

    static func parseMotionBGs(_ html: String) -> [SourceResult] {
        let pattern = #"<a title="([^"]+) (?:live|animated) wallpaper" href=(/[^>]+)>.*?src=(/i/c/\d+x\d+/media/(\d+)/[^"> ]+)"#
        var seen = Set<String>()
        return matches(pattern, in: html, dotAll: true).compactMap { groups in
            guard seen.insert(groups[4]).inserted,
                  let thumbnail = URL(string: "https://motionbgs.com" + groups[3])
            else { return nil }
            return SourceResult(
                source: .motionBGs, key: groups[4], title: unescapeHTML(groups[1]), thumbnail: thumbnail
            )
        }
    }

    static func parseWallper(_ html: String, category: String) -> [SourceResult] {
        let pattern = #"aria-label="([^"]+)" href="/wallpaper/[a-z0-9-]+/([a-z0-9-]+)">.*?url=([^&"]+)&"#
        var seen = Set<String>()
        return matches(pattern, in: html, dotAll: true).compactMap { groups in
            let slug = groups[2]
            guard slug.count >= 36 else { return nil }
            let uuid = String(slug.suffix(36))
            guard isUUID(uuid), seen.insert(uuid).inserted,
                  let decoded = groups[3].removingPercentEncoding,
                  let thumbnail = URL(string: decoded)
            else { return nil }
            return SourceResult(
                source: .wallper, key: uuid, title: unescapeHTML(groups[1]),
                thumbnail: thumbnail, category: category
            )
        }
    }

    /// The items embedded in Wallper's gallery page. They arrive as escaped
    /// JSON inside the page's own data, which is why the quotes are unescaped
    /// first rather than the page being parsed as HTML.
    static func parseWallperCatalogue(_ html: String) -> [SourceResult] {
        let unescaped = html.replacingOccurrences(of: "\\\"", with: "\"")
        // `[^{}]` keeps a match inside one item, whatever follows it.
        let pattern = #""id":"([0-9a-f-]{36})","age":"([^"]*)"[^{}]*?"name":"([^"]*)"[^{}]*?"previewImageKey":"([^"]+)""#
        var seen = Set<String>()
        return matches(pattern, in: unescaped, dotAll: true).compactMap { groups in
            let id = groups[1]
            guard isUUID(id), seen.insert(id).inserted,
                  let thumbnail = URL(string: "https://cdn.wallper.app/previews/\(groups[4])")
            else { return nil }
            return SourceResult(
                source: .wallper, key: id, title: unescapeHTML(groups[3]),
                thumbnail: thumbnail, category: groups[2].lowercased()
            )
        }
    }

    // MARK: - Plumbing

    /// Reads a browse from the cache when it can, and falls back to a stale
    /// copy when the site cannot be reached. A refresh asked for by the user
    /// skips both, and reports the failure.
    private static func cached(
        source: WallpaperSource,
        scope: String,
        page: Int,
        refresh: Bool,
        fetch: () async throws -> [SourceResult]
    ) async throws -> [SourceResult] {
        let key = SourceCache.key(source: source, scope: scope, page: page)
        if !refresh, let hit = SourceCache.read(key) { return hit }
        do {
            let fresh = try await fetch()
            SourceCache.write(fresh, for: key)
            return fresh
        } catch {
            if !refresh, let stale = SourceCache.readStale(key) { return stale }
            throw error
        }
    }

    static func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SourceError.unreachable
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.server(status: http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func matches(_ pattern: String, in text: String, dotAll: Bool = false) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : []
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func isUUID(_ text: String) -> Bool {
        text.count == 36 && UUID(uuidString: text) != nil
    }
}
