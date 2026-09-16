import CoreAudio
import Foundation

/// Whether anything else on this Mac is playing sound.
///
/// A wallpaper with its own audio should get out of the way the moment you
/// start a video, a call or some music, and come back when the Mac goes quiet
/// again.
///
/// It reads CoreAudio's public process list: the audio hardware keeps one
/// object per process that has touched an output device, each saying whether
/// audio is actually flowing right now rather than merely that the process has
/// a device open. Muro's own process is excluded
public final class SystemAudioMonitor {
    public private(set) var otherAudioIsPlaying = false

    public var onChange: ((Bool) -> Void)?

    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    deinit { timer?.invalidate() }

    public func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        guard otherAudioIsPlaying else { return }
        otherAudioIsPlaying = false
        onChange?(false)
    }

    private func poll() {
        let playing = Self.otherProcessIsPlaying(excluding: ownPID)
        guard playing != otherAudioIsPlaying else { return }
        otherAudioIsPlaying = playing
        onChange?(playing)
    }

    private static func otherProcessIsPlaying(excluding ownPID: pid_t) -> Bool {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return false }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &dataSize, &processes
        ) == noErr else { return false }

        for process in processes {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != ownPID
            else { continue }

            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                process, &runningAddress, 0, nil, &runningSize, &isRunning
            ) == noErr else { continue }
            if isRunning != 0 { return true }
        }
        return false
    }
}
