import SwiftUI
import MuroKit

/// What Muro tells user about Wallpaper Engine scenes, in one place so the
/// Explore tab, the preview and the documentation cannot drift apart.
enum SceneEngineNotice {
    static let title = "Scenes are in beta"

    static let message = """
    Wallpaper Engine's scene format is not documented, so Muro's support for it \
    was worked out from real Workshop items. A scene can look wrong, be missing \
    an effect, or fail to load, and this part is still being worked on.

    Some scenes also need Wallpaper Engine's own built-in textures, which Muro \
    does not ship. If one looks incomplete, copy those from your own install \
    into the folder in Settings, under Wallpaper Engine.

    Video wallpapers are not affected by any of this.
    """

    static let short = "Scenes are in beta: some may look wrong, miss effects, or need Wallpaper Engine's own textures."
}

struct SceneEngineNoticeCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.muroWarn)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.muroWarn.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(SceneEngineNotice.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Scene wallpapers are translated from a format Muro (from WER) had to work out, so some come out wrong or need Wallpaper Engine's own textures. Video wallpapers are not affected.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.muroSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.glassSheen(0.09, 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.muroWarn.opacity(0.28), lineWidth: 1)
        )
    }
}

struct SceneWarningButton: View {
    var item: WallpaperItem?

    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            ZStack {
                Circle().fill(Color.muroWarn.opacity(0.16))
                Circle().strokeBorder(Color.muroWarn.opacity(0.45), lineWidth: 1)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.muroWarn)
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .help(SceneEngineNotice.short)
        .anchoredCard(isPresented: $showing, width: 340, align: .center) {
            SceneEngineNoticeDetail(item: item) { showing = false }
        }
    }
}

struct SceneEngineNoticeDetail: View {
    var item: WallpaperItem?
    var dismiss: () -> Void

    @ObservedObject private var sources = SourceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.muroWarn)
                Text(SceneEngineNotice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(SceneEngineNotice.message)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.muroSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    SourceStore.shared.revealStockAssets()
                    dismiss()
                } label: {
                    Text("Show Textures Folder")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)
                if let item, item.isScene {
                    Button {
                        sources.reimportScene(item)
                        dismiss()
                    } label: {
                        Text(sources.downloads[item.id] != nil ? "Translating…" : "Translate Again")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(sources.downloads[item.id] != nil)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
