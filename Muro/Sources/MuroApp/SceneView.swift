import SwiftUI
import AppKit
import MuroKit

/// A Wallpaper Engine scene rendered live inside the app: the Home hero and
/// the full window preview.
struct SceneView: NSViewRepresentable {
    let directory: URL
    var isActive = true

    func makeNSView(context: Context) -> SceneNSView { SceneNSView() }

    func updateNSView(_ view: SceneNSView, context: Context) {
        view.show(directory: directory)
        view.setActive(isActive)
    }
}

final class SceneNSView: NSView {
    private var surface: SceneSurface?
    private var directory: URL?
    private var failed = false
    private var isActive = true
    private var occlusionObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(directory: URL) {
        guard directory != self.directory else { return }
        self.directory = directory
        surface?.invalidate()
        surface = nil
        failed = false
        needsLayout = true
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        updateSuspension()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        if surface == nil, !failed, let directory, window != nil, bounds.width > 1, bounds.height > 1 {
            if let made = SceneSurface(sceneDirectory: directory, size: bounds.size, scale: scale) {
                made.window = window
                layer?.addSublayer(made.layer)
                surface = made
            } else {
                failed = true
            }
        } else if let surface, surface.layer.frame.size != bounds.size {
            surface.resize(to: bounds.size, scale: scale)
        }
        updateSuspension()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            surface?.window = window
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                self?.updateSuspension()
            }
        } else {
            surface?.invalidate()
            surface = nil
        }
        needsLayout = true
    }

    private func updateSuspension() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        surface?.setSuspended(!(isActive && visible))
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        surface?.invalidate()
    }
}
