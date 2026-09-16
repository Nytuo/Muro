import SwiftUI
import MuroKit

/// Where Explore is browsing: Muro's own catalog, or one of the outside
/// sources a wallpaper can be downloaded from.
enum ExploreSource: String, CaseIterable, Identifiable {
    case muro, workshop, motionBGs, wallper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .muro: return "Muro"
        case .workshop: return "Wallpaper Engine Workshop"
        case .motionBGs: return "MotionBGs"
        case .wallper: return "Wallper"
        }
    }

    var systemImage: String {
        switch self {
        case .muro: return "sparkles"
        case .workshop: return "cube.transparent"
        case .motionBGs: return "play.rectangle"
        case .wallper: return "square.grid.2x2"
        }
    }
}

/// One outside source's results, pages and filters. Kept alive by Explore for
/// the life of the window, so switching sources back and forth does not throw
/// away a browse and fetch it again.
@MainActor
final class SourceBrowserModel: ObservableObject {
    let source: WallpaperSource

    @Published var query = ""
    @Published var workshopType: WorkshopItemType = .any
    @Published var category = "anime"
    @Published private(set) var results: [SourceResult] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var exhausted = false
    @Published private(set) var refreshing = false

    private var page = 1
    private var generation = 0

    init(source: WallpaperSource) {
        self.source = source
    }

    func reload(refresh: Bool = false) {
        page = 1
        results = []
        exhausted = false
        load(refresh: refresh)
    }

    func loadMore() {
        guard !loading, !exhausted, failure == nil else { return }
        page += 1
        load()
    }

    func retry() {
        failure = nil
        results.isEmpty ? reload() : load()
    }

    private func load(refresh: Bool = false) {
        generation += 1
        let token = generation
        loading = true
        refreshing = refresh
        failure = nil
        let source = source, query = query, type = workshopType, category = category, page = page
        Task {
            do {
                let batch: [SourceResult]
                switch source {
                case .workshop:
                    batch = try await SourceBrowser.workshop(query: query, type: type, page: page, refresh: refresh)
                case .motionBGs:
                    batch = try await SourceBrowser.motionBGs(query: query, page: page, refresh: refresh)
                case .wallper:
                    batch = try await SourceBrowser.wallper(
                        query: query, category: category, page: page, refresh: refresh
                    )
                }
                guard token == generation else { return }
                let known = Set(results.map(\.id))
                let fresh = batch.filter { !known.contains($0.id) }
                results += fresh
                exhausted = fresh.isEmpty
            } catch {
                guard token == generation else { return }
                failure = error.localizedDescription
                if page > 1 { self.page -= 1 }
            }
            if token == generation {
                loading = false
                refreshing = false
            }
        }
    }
}

/// Explore for one outside source: its own filters on top, the same grid and
/// cards as the catalog below.
struct SourceBrowserView: View {
    @ObservedObject var model: SourceBrowserModel
    @EnvironmentObject var store: AppStore
    @ObservedObject private var sources = SourceStore.shared
    @AppStorage("motionBGsQuality") private var qualityRaw = MotionBGsQuality.hd.rawValue

    private var quality: MotionBGsQuality { MotionBGsQuality(rawValue: qualityRaw) ?? .hd }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
                .padding(.horizontal, 40)
                .padding(.top, 14)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    if model.source == .workshop {
                        SceneEngineNoticeCard()
                    }
                    if model.source == .workshop, !sources.workshopReady {
                        WorkshopAccountCard()
                    }
                    if model.source == .workshop, let id = SourceBrowser.workshopID(from: model.query) {
                        pastedItemRow(id)
                    }
                    content
                }
                .padding(.horizontal, 40)
                .padding(.top, 22)
                .padding(.bottom, 40)
            }
            .scrollFade(top: 22, bottom: 46)
        }
        .onAppear {
            if model.results.isEmpty, !model.loading, model.failure == nil { model.reload() }
        }
    }

    // MARK: - Controls

    @ViewBuilder private var controls: some View {
        switch model.source {
        case .workshop:
            HStack(spacing: 12) {
                searchField("Search the Workshop, or paste a link")
                Spacer(minLength: 12)
                PillSegments(
                    options: WorkshopItemType.allCases.map { PillOption($0.rawValue, $0.rawValue) },
                    selection: Binding(
                        get: { model.workshopType.rawValue },
                        set: { raw in
                            guard let type = WorkshopItemType(rawValue: raw), type != model.workshopType else { return }
                            model.workshopType = type
                            model.reload()
                        }
                    ),
                    height: 34, labelSize: 12, horizontalPadding: 15
                )
                .help("Only Scene and Video wallpapers play on a Mac")
                refreshButton
            }
            .frame(height: 48)
        case .motionBGs:
            HStack(spacing: 12) {
                searchField("Search MotionBGs")
                Spacer(minLength: 12)
                Text("Quality")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.muroSecondary)
                PillSegments(
                    options: MotionBGsQuality.allCases.map { PillOption($0.rawValue, $0.label) },
                    selection: $qualityRaw,
                    height: 34, labelSize: 12, horizontalPadding: 16
                )
                refreshButton
            }
            .frame(height: 48)
        case .wallper:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    searchField("Search Wallper")
                    Spacer(minLength: 12)
                    refreshButton
                }
                if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        PillSegments(
                            options: SourceBrowser.wallperCategories.map { PillOption($0, $0.capitalized) },
                            selection: Binding(
                                get: { model.category },
                                set: { new in
                                    guard new != model.category else { return }
                                    model.category = new
                                    model.reload()
                                }
                            ),
                            height: 34, labelSize: 12, horizontalPadding: 14
                        )
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                    }
                    .frame(height: 44)
                }
            }
        }
    }

    /// Browses are remembered for a day, so the sites are asked once rather
    /// than on every visit. This is how somebody asks anyway.
    private var refreshButton: some View {
        Button {
            model.reload(refresh: true)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.glassSheen(0.10, 0.045)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.13), lineWidth: 1))
                .rotationEffect(.degrees(model.refreshing ? 360 : 0))
                .animation(
                    model.refreshing
                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                        : .default,
                    value: model.refreshing
                )
        }
        .buttonStyle(.plain)
        .disabled(model.loading)
        .help("Fetch this page again instead of using what was saved")
    }

    private func searchField(_ placeholder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.muroSecondary)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .onSubmit { model.reload() }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.reload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muroSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 340, height: 40)
        .glassCapsule(fill: 0.08, stroke: 0.14)
    }

    private func pastedItemRow(_ id: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.muroAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Workshop item \(id)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Download it straight from the link.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.muroSecondary)
            }
            Spacer(minLength: 12)
            accentButton("Download", systemImage: "arrow.down") {
                sources.downloadWorkshop(id: id, title: "Workshop item \(id)")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 13)
        .glassPanel(cornerRadius: 16)
    }

    // MARK: - Results

    @ViewBuilder private var content: some View {
        if model.results.isEmpty {
            if model.loading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large).tint(Color.muroAccent)
                    Text("Loading wallpapers…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.muroSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 84)
            } else if let failure = model.failure {
                emptyState(
                    symbol: "wifi.slash",
                    title: "\(model.source.name) is not answering",
                    detail: failure,
                    retry: true
                )
            } else {
                emptyState(
                    symbol: "sparkle.magnifyingglass",
                    title: "Nothing found",
                    detail: model.query.isEmpty ? "Try another category." : "Try another word.",
                    retry: false
                )
            }
        } else {
            LazyVGrid(columns: gridColumns, spacing: 24) {
                ForEach(model.results) { result in
                    SourceCard(result: result, quality: quality)
                        .onAppear {
                            if result.id == model.results.last?.id { model.loadMore() }
                        }
                }
            }
            footer
        }
    }

    @ViewBuilder private var footer: some View {
        if model.loading {
            ProgressView().controlSize(.small).tint(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        } else if let failure = model.failure {
            HStack(spacing: 12) {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muroSecondary)
                accentButton("Try Again", systemImage: "arrow.clockwise") { model.retry() }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func emptyState(symbol: String, title: String, detail: String, retry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.muroAccent)
                .frame(width: 54, height: 54)
                .background(Circle().fill(.glassSheen(0.14, 0.05)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muroSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if retry {
                accentButton("Try Again", systemImage: "arrow.clockwise") { model.retry() }
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func accentButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Color.muroAccent)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(Capsule().fill(Color.muroAccent.opacity(0.13)))
            .overlay(Capsule().strokeBorder(Color.muroAccent.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card

struct SourceCard: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var sources = SourceStore.shared
    let result: SourceResult
    var quality: MotionBGsQuality

    @State private var hovering = false

    private var local: WallpaperItem? { sources.libraryItem(for: result) }
    private var progress: Double? { sources.downloads[result.origin] }

    var body: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: result.thumbnail) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.04)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .bottom) { title }
            .overlay(alignment: .topLeading) {
                if local != nil { AppliedChip(label: "IN LIBRARY").padding(12) }
            }
            .overlay(alignment: .bottomTrailing) { control.padding(12) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.16 : 0.07), lineWidth: 1)
            )
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture(perform: activate)
            .help(local == nil ? "Download \(result.title)" : "Open \(result.title)")
    }

    private var title: some View {
        Text(result.title)
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.trailing, 34)
            .padding(.top, 34)
            .padding(.bottom, 14)
            .background(
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            )
    }

    @ViewBuilder private var control: some View {
        if let progress {
            ZStack {
                if progress >= 1 {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    ProgressView(value: max(0.02, progress))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                }
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.black.opacity(0.45)))
        } else if local == nil {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.6 : 0.4)))
        }
    }

    private func activate() {
        if let local {
            store.openPreview(local)
            return
        }
        guard progress == nil else { return }
        switch result.source {
        case .workshop:
            sources.downloadWorkshop(id: result.key, title: result.title)
        case .motionBGs, .wallper:
            sources.download(result, quality: quality)
        }
    }
}

// MARK: - Workshop account

/// What Workshop downloads need, said once, with the two things to do about
/// it. Shown above the Workshop grid until it is ready, and in Settings.
struct WorkshopAccountCard: View {
    @ObservedObject private var sources = SourceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 13) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.muroAccent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.muroAccent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wallpaper Engine Workshop")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Downloads need a Steam account that owns Wallpaper Engine. Scene and Video wallpapers play on your Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.muroSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !sources.depotInstalled {
                HStack(spacing: 12) {
                    Text("Muro downloads through DepotDownloader, an open source Steam client, fetched from GitHub once.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.muroSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if sources.installingDepot {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Button { sources.installDepot() } label: {
                            Text("Set Up")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 20)
                                .frame(height: 36)
                                .background(Capsule().fill(Color.white))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    PillSegments(
                        options: [PillOption("login", "Steam login"), PillOption("qr", "QR code")],
                        selection: Binding(
                            get: { sources.workshopUsesQR ? "qr" : "login" },
                            set: { sources.workshopUsesQR = $0 == "qr" }
                        ),
                        height: 32, labelSize: 12, horizontalPadding: 14
                    )
                    if !sources.workshopUsesQR {
                        GlassTextField(label: "STEAM USERNAME", placeholder: "Account name", text: $sources.workshopUsername)
                    } else {
                        Text("Scan the code with the Steam app when the download starts.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.muroSecondary)
                    }
                }
                Text("Your password is asked for when Steam needs it, handed straight to DepotDownloader, and never stored.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.muroSecondary.opacity(0.8))
            }
        }
        .padding(20)
        .glassPanel()
    }
}

// MARK: - Workshop download sheet

/// A Workshop download while it runs: the sign in it needs, how far it has
/// got, and what came of it.
struct WorkshopDownloadSheet: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var sources = SourceStore.shared
    @State private var answer = ""

    var body: some View {
        if let session = sources.workshop {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Steam Workshop") { sources.closeWorkshop() }
                    .padding(.horizontal, 26)
                    .padding(.top, 26)

                Text(session.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 26)
                    .padding(.top, 14)
                status(session)
                    .padding(.horizontal, 26)
                    .padding(.top, 6)

                if let grid = session.qrCode {
                    HStack(spacing: 18) {
                        QRCodeView(grid: grid)
                            .frame(width: 180, height: 180)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("SIGN IN")
                            Text("Open the Steam app on your phone, tap the shield, and scan this code.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 18)
                }

                if let prompt = session.prompt {
                    promptField(prompt)
                        .padding(.horizontal, 26)
                        .padding(.top, 18)
                }

                log(session.lines)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 18)

                SheetFooter {
                    Text("Needs a Steam account that owns Wallpaper Engine")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.muroSecondary)
                } actions: {
                    switch session.phase {
                    case .running:
                        DangerPill(title: "Cancel") { sources.cancelWorkshop() }
                    case .importing:
                        EmptyView()
                    case .done, .failed:
                        GhostPill(title: "Close") { sources.closeWorkshop() }
                    }
                }
            }
            .frame(width: 580, height: 600)
            .sheetSurface()
        }
    }

    @ViewBuilder private func status(_ session: SourceStore.WorkshopSession) -> some View {
        switch session.phase {
        case .running:
            HStack(spacing: 10) {
                if let progress = session.progress {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(Color.muroAccent).frame(width: 140)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.muroSecondary)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(session.qrCode != nil ? "Waiting for the scan…" : session.prompt != nil ? "Steam is asking…" : "Connecting to Steam…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.muroSecondary)
                }
            }
        case .importing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Adding it to your Library…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.muroSecondary)
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.muroGreen)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.muroWarn)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func promptField(_ prompt: WorkshopDownload.Prompt) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(prompt == .password ? "STEAM PASSWORD" : "STEAM GUARD CODE")
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.muroAccent)
                Group {
                    if prompt == .password {
                        SecureField("Password", text: $answer)
                    } else {
                        TextField("Code from the Steam app or email", text: $answer)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .onSubmit(send)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.glassSheen(0.085, 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.muroAccent.opacity(0.4), lineWidth: 1))
            PrimaryPill(title: "Send", enabled: !answer.isEmpty, action: send)
        }
    }

    private func send() {
        guard !answer.isEmpty else { return }
        sources.answerWorkshopPrompt(answer)
        answer = ""
    }

    /// The raw DepotDownloader log, for when something goes wrong.
    private func log(_ lines: [String]) -> some View {
        let visible = lines.filter { line in
            !line.isEmpty && !line.allSatisfy({ $0 == "█" || $0 == " " || $0 == "▀" || $0 == "▄" })
        }
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(visible.suffix(200).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .onChange(of: visible.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// Real square modules, so the code scans whatever the font would have done.
struct QRCodeView: View {
    let grid: [[Bool]]

    var body: some View {
        Canvas { context, size in
            let rows = grid.count
            let columns = grid.first?.count ?? 0
            guard rows > 0, columns > 0 else { return }
            let cell = min(size.width / CGFloat(columns), size.height / CGFloat(rows))
            let originX = (size.width - cell * CGFloat(columns)) / 2
            let originY = (size.height - cell * CGFloat(rows)) / 2
            for (y, row) in grid.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    context.fill(
                        Path(CGRect(x: originX + CGFloat(x) * cell, y: originY + CGFloat(y) * cell, width: cell, height: cell)),
                        with: .color(.black)
                    )
                }
            }
        }
    }
}
