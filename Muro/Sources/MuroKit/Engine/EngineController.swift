import AppKit

/// Library mode: reads library.json + config.json, keeps one wallpaper
/// window per assigned display, and reconciles whenever the config changes
/// on disk (hot-reload) or displays are connected/disconnected.
public final class EngineController {
    private let root = LibraryManifest.defaultRoot()
    private var controllers: [String: WallpaperWindowController] = [:]
    /// Split deliberately. The window's geometry is the only thing that needs
    /// a rebuild; the video is swapped in place, because tearing the window
    /// down for a wallpaper change flashed black on every switch.
    private var frames: [String: String] = [:]
    private var videos: [String: String] = [:]
    private var configWatcher: DispatchSourceFileSystemObject?
    private var observers: [NSObjectProtocol] = []
    private let power = PowerMonitor()
    private let desktopWindows = DesktopWindowMonitor()
    private let systemAudio = SystemAudioMonitor()

    public init() {}

    public func start() {
        power.onChange = { [weak self] in self?.applyPowerState() }
        power.start()
        desktopWindows.onUpdate = { [weak self] covered, hidden in
            self?.applyDesktopCoverage(covered, hidden: hidden)
        }
        systemAudio.onChange = { [weak self] playing in
            guard let self else { return }
            for controller in self.controllers.values { controller.setDucked(playing) }
        }
        reconcile()
        watchConfigDirectory()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            EngineLog.log("displays changed — reconciling")
            self?.reconcile()
        })
    }

    /// Takes every wallpaper window off the screen, for a quit.
    ///
    /// Muro's own window is what the desktop shows while Muro runs, so this is
    /// what hands the screen back to the picture macOS itself holds. Done
    /// before the process goes rather than by the process going, so the app is
    /// still alive afterwards to ask for that picture to be drawn again while
    /// it is the thing on screen.
    public func stopAll() {
        for controller in controllers.values { controller.stop() }
        controllers.removeAll()
        frames.removeAll()
        videos.removeAll()
    }

    /// Watches the library root for writes; config.json is saved atomically
    /// so directory-level write events are the reliable signal.
    private func watchConfigDirectory() {
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else {
            EngineLog.log("warning: cannot watch \(root.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.reconcile() }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    private func reconcile() {
        // A manifest that could not be read is not an empty library. Treating
        // it as one leaves nothing assigned to any display, and the engine
        // answers that by taking every wallpaper off the screen: a damaged
        // file would blank the desktop as well as stalling the app.
        let manifest: LibraryManifest
        switch LibraryManifest.state(root: root) {
        case .loaded(let loaded):
            manifest = loaded
        case .missing:
            manifest = LibraryManifest()
        case .damaged:
            EngineLog.log("library.json could not be read — leaving the screen as it is")
            return
        }
        let config = EngineConfig.load(root: root)

        var desired: [String: (screen: NSScreen, content: WallpaperWindowController.Content,
                               frame: String, video: String, pauseAfter: Int?)] = [:]
        for screen in NSScreen.screens {
            guard let uuid = displayUUID(for: screen) else { continue }
            guard let assignment = config.assignment(forDisplayUUID: uuid),
                  let entry = manifest.wallpapers.first(where: { $0.id == assignment.wallpaperID })
            else { continue }
            let content: WallpaperWindowController.Content
            let required: URL
            if let scene = entry.scene {
                let directory = root.appendingPathComponent(scene, isDirectory: true)
                content = .scene(directory)
                required = directory.appendingPathComponent("scene.json")
            } else {
                let url = resolveVideoURL(entry: entry, mode: assignment.mode, root: root)
                content = .video(url)
                required = url
            }
            guard FileManager.default.fileExists(atPath: required.path) else {
                EngineLog.log("skipping \(entry.title) — missing file \(required.lastPathComponent)")
                continue
            }
            desired[uuid] = (
                screen,
                content,
                NSStringFromRect(screen.frame),
                Self.contentKey(entry: entry, mode: assignment.mode, required: required),
                // A wallpaper may carry its own "pause after"; otherwise the
                // one global setting applies. `PauseAfter` owns the rule,
                // including the part that is easy to get wrong: a wallpaper
                // set to zero never freezes and does not fall back.
                PauseAfter.resolve(
                    wallpaper: entry.pauseAfterSeconds,
                    global: config.pauseAfterSeconds
                )
            )
        }

        // Tear down displays that lost their assignment, or whose geometry
        // changed. A resolution or arrangement change genuinely needs a new
        // window; a different wallpaper does not.
        for (uuid, controller) in controllers where desired[uuid]?.frame != frames[uuid] {
            controller.stop()
            controllers[uuid] = nil
            frames[uuid] = nil
            videos[uuid] = nil
        }

        // Bring up displays that need a (new) wallpaper.
        for (uuid, want) in desired where controllers[uuid] == nil {
            let controller = WallpaperWindowController(screen: want.screen, content: want.content)
            controller.start()
            controllers[uuid] = controller
            frames[uuid] = want.frame
            videos[uuid] = want.video
            EngineLog.log("applied \(want.content.url.lastPathComponent) → \(want.screen.localizedName)")
        }

        // Same window, different wallpaper: crossfade to it in place.
        for (uuid, want) in desired {
            guard let controller = controllers[uuid], videos[uuid] != want.video else { continue }
            controller.setContent(want.content)
            videos[uuid] = want.video
        }

        // Live-applied state that never needs a window rebuild.
        let paused = config.paused ?? false
        let rate = Float(config.playbackSpeed ?? 1.0)
        let pauseWhenCovered = config.autoPauseFullScreen ?? true
        for (uuid, controller) in controllers {
            controller.setUserPaused(paused)
            controller.setPlaybackRate(rate)
            controller.setAutoPauseFullScreen(pauseWhenCovered)
            controller.setVolume(config.volume)
            controller.setDucked(systemAudio.otherAudioIsPlaying)
            controller.setPauseAfter(desired[uuid]?.pauseAfter)
        }
        applyPowerState(config: config)
        applyDesktopRules(config: config)
        applyAudioRules(config: config)
    }

    private static func contentKey(entry: WallpaperEntry, mode: String, required: URL) -> String {
        guard entry.isScene else { return "\(entry.id)|\(mode)" }
        let written = (try? FileManager.default.attributesOfItem(atPath: required.path)[.modificationDate]) as? Date
        return "\(entry.id)|scene|\(Int(written?.timeIntervalSince1970 ?? 0))"
    }

    /// Issue #22. Hands both desktop switches to every display, and keeps the
    /// window check running only while one of them is on, so nobody pays for
    /// it otherwise.
    private func applyDesktopRules(config: EngineConfig) {
        let playOnlyOnDesktop = config.playOnlyOnDesktop ?? false
        let replayOnClearDesktop = config.replayOnClearDesktop ?? false
        for controller in controllers.values {
            controller.setDesktopRules(
                playOnlyOnDesktop: playOnlyOnDesktop, replayOnClearDesktop: replayOnClearDesktop
            )
        }
        if DesktopPlayback.needsWindowCheck(
            playOnlyOnDesktop: playOnlyOnDesktop,
            replayOnClearDesktop: replayOnClearDesktop,
            autoPauseWhenCovered: config.autoPauseFullScreen ?? true
        ) {
            desktopWindows.start()
        } else {
            desktopWindows.stop()
            for controller in controllers.values {
                controller.setDesktopCovered(nil)
                controller.setDesktopHidden(nil)
            }
        }
    }

    /// Nobody pays for the audio watch unless the wallpaper can actually make
    /// a sound: a silent library, or the sound switched off, and the monitor
    /// is not running at all.
    private func applyAudioRules(config: EngineConfig) {
        let wanted = config.volume > 0 && (config.autoMuteWithOtherAudio ?? true)
        if wanted {
            systemAudio.start()
        } else {
            systemAudio.stop()
            for controller in controllers.values { controller.setDucked(false) }
        }
    }

    private func applyDesktopCoverage(_ covered: Set<String>, hidden: Set<String>) {
        for (uuid, controller) in controllers {
            controller.setDesktopHidden(hidden.contains(uuid))
            controller.setDesktopCovered(covered.contains(uuid))
        }
    }

    /// Combines the Settings toggles (from config.json) with the live power
    /// state. Runs on every reconcile (config edits, display changes) and on
    /// every PowerMonitor flip, so both sides stay in sync.
    private func applyPowerState(config: EngineConfig? = nil) {
        let config = config ?? EngineConfig.load(root: root)
        let lowPower = (config.autoPauseLowPower ?? false) && power.isLowPowerMode
        let lowBattery = (config.autoPauseBattery ?? false) && power.isLowBattery
        for controller in controllers.values {
            controller.setPowerPause(lowPower: lowPower, lowBattery: lowBattery)
        }
    }
}
