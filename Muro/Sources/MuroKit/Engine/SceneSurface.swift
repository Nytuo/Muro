import AVFoundation
import AppKit
import CSceneEngine
import Metal
import QuartzCore

/// A Wallpaper Engine scene drawn live into a `CAMetalLayer`.
///
/// The picture comes from the Rust scene engine (`SceneEngine/`): image
/// layers, the effect chain and particles, composited by wgpu on Metal.
public final class SceneSurface {
    public let layer = CAMetalLayer()

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var suspended = false
    public private(set) var animates = false
    private var parallax = false

    /// The window whose frame the pointer is measured against for parallax.
    public weak var window: NSWindow?

    /// The rate the effect chain was tuned against the WE Scene Engine
    /// Enough for water ripples and drifting particles, and
    /// half the GPU time of matching a 60 Hz display.
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    /// A scene's own sound, when it has any and the user has asked for it.
    private var audioPlayer: AVQueuePlayer?
    private var audioLooper: AVPlayerLooper?
    private var audioLayerVolume: Float = 1
    private var volume: Double = 0
    private var description: SceneDescription?

    /// Fails when there is no Metal device or the scene cannot be loaded or
    /// attached. The caller shows the thumbnail instead of an empty layer.
    public init?(sceneDirectory: URL, size: CGSize, scale: CGFloat, volume: Double = 0) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let handle = wer_engine_create()
        else { return nil }

        guard sceneDirectory.path.withCString({ wer_engine_load_scene(handle, $0) }) == 0 else {
            EngineLog.log("scene engine could not load \(sceneDirectory.lastPathComponent)")
            wer_engine_destroy(handle)
            return nil
        }

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.contentsScale = scale
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        let pixels = Self.pixelSize(size, scale: scale)
        layer.drawableSize = CGSize(width: CGFloat(pixels.width), height: CGFloat(pixels.height))
        layer.frame = CGRect(origin: .zero, size: size)

        let pointer = Unmanaged.passUnretained(layer).toOpaque()
        guard wer_engine_attach_metal_layer(handle, pointer, pixels.width, pixels.height) == 0 else {
            EngineLog.log("scene engine could not attach a Metal layer")
            wer_engine_destroy(handle)
            return nil
        }

        self.handle = handle
        animates = wer_engine_needs_animation(handle) != 0
        description = SceneDescription.read(directory: sceneDirectory)
        if let description {
            parallax = description.parallaxEnabled && description.parallaxAmount > 0
        }
        wer_engine_tick(handle)
        updateTimer()
        setVolume(volume)
    }

    deinit {
        timer?.invalidate()
        tearDownAudio()
        if let handle { wer_engine_destroy(handle) }
    }

    public var hasAudio: Bool { description?.audio.isEmpty == false }

    public func setVolume(_ newVolume: Double) {
        let clamped = max(0, min(1, newVolume))
        let wasSilent = volume == 0
        volume = clamped
        if clamped == 0 {
            tearDownAudio()
            return
        }
        if wasSilent || audioPlayer == nil { setUpAudio() }
        audioPlayer?.volume = Float(clamped) * audioLayerVolume
    }

    private func setUpAudio() {
        guard audioPlayer == nil, let layer = description?.audio.first,
              FileManager.default.fileExists(atPath: layer.url.path)
        else { return }
        audioLayerVolume = Float(layer.volume)
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.volume = Float(volume) * audioLayerVolume
        audioLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: layer.url))
        audioPlayer = player
        if !suspended { player.play() }
    }

    private func tearDownAudio() {
        audioLooper?.disableLooping()
        audioPlayer?.pause()
        audioPlayer?.removeAllItems()
        audioLooper = nil
        audioPlayer = nil
    }

    public func setSuspended(_ value: Bool) {
        guard value != suspended, let handle else { return }
        suspended = value
        wer_engine_set_occluded(handle, value ? 1 : 0)
        if !value { wer_engine_tick(handle) }
        value ? audioPlayer?.pause() : audioPlayer?.play()
        updateTimer()
    }

    public func resize(to size: CGSize, scale: CGFloat) {
        guard let handle else { return }
        let pixels = Self.pixelSize(size, scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: CGFloat(pixels.width), height: CGFloat(pixels.height))
        CATransaction.commit()
        wer_engine_resize(handle, pixels.width, pixels.height)
        if !suspended { wer_engine_tick(handle) }
    }

    /// Releases the GPU surface now rather than whenever the last reference
    /// happens to go. The wallpaper window calls it when it swaps away.
    public func invalidate() {
        timer?.invalidate()
        timer = nil
        tearDownAudio()
        if let handle { wer_engine_destroy(handle) }
        handle = nil
        layer.removeFromSuperlayer()
    }

    private func updateTimer() {
        let wanted = !suspended && handle != nil && (animates || parallax)
        if wanted, timer == nil {
            let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
                self?.frame()
            }
            timer.tolerance = Self.frameInterval / 4
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func frame() {
        guard let handle, !suspended else { return }
        if parallax, let window {
            let frame = window.frame
            let mouse = NSEvent.mouseLocation
            if frame.width > 0, frame.height > 0 {
                let x = Float((mouse.x - frame.midX) / (frame.width / 2))
                let y = Float((mouse.y - frame.midY) / (frame.height / 2))
                wer_engine_set_parallax_mouse_position(
                    handle, max(-1, min(1, x)), max(-1, min(1, -y))
                )
            }
        }
        wer_engine_tick(handle)
    }

    private static func pixelSize(_ size: CGSize, scale: CGFloat) -> (width: UInt32, height: UInt32) {
        (UInt32(max(1, (size.width * scale).rounded())), UInt32(max(1, (size.height * scale).rounded())))
    }
}

/// What the scene engine says a materialized scene directory holds.
public struct SceneDescription {
    public struct AudioLayer {
        public var url: URL
        public var volume: Double
    }

    public var title: String
    public var isLayered: Bool
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var parallaxEnabled: Bool
    public var parallaxAmount: Double
    public var audio: [AudioLayer] = []

    public static func read(directory: URL) -> SceneDescription? {
        guard let raw = directory.path.withCString({ wer_resolve_wallpaper($0) }) else { return nil }
        defer { wer_free_string(raw) }
        guard let data = String(cString: raw).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let audio = (json["layers"] as? [[String: Any]] ?? []).compactMap { layer -> AudioLayer? in
            guard layer["kind"] as? String == "audio", let asset = layer["asset"] as? String else { return nil }
            return AudioLayer(
                url: URL(fileURLWithPath: asset),
                volume: (layer["volume"] as? NSNumber)?.doubleValue ?? 1
            )
        }
        return SceneDescription(
            title: json["title"] as? String ?? "",
            isLayered: json["kind"] as? String == "layered",
            canvasWidth: (json["canvas_width"] as? NSNumber)?.doubleValue ?? 0,
            canvasHeight: (json["canvas_height"] as? NSNumber)?.doubleValue ?? 0,
            parallaxEnabled: json["parallax_enabled"] as? Bool ?? false,
            parallaxAmount: (json["parallax_amount"] as? NSNumber)?.doubleValue ?? 0,
            audio: audio
        )
    }
}
