import AVFoundation
import VideoToolbox
import Foundation

public struct TranscodeResult {
    public let width: Int
    public let height: Int
    public let fps: Double
    public let duration: Double
    public var hasAudio: Bool = false
}

public enum TranscodeError: Error, CustomStringConvertible {
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)

    public var description: String {
        switch self {
        case .noVideoTrack: return "source has no video track"
        case .readerFailed(let why): return "reader failed: \(why)"
        case .writerFailed(let why): return "writer failed: \(why)"
        }
    }
}

/// Re-encodes a video to HEVC (.mov). Frame rate is preserved unless
/// `halveFrameRate` is set, which drops every second frame — the cheap, exact
/// way to turn 60 fps into 30 fps for the "Efficient" playback mode. Decoding
/// and encoding are both hardware (Media Engine) on Apple Silicon.
///
/// An audio track is carried across untouched, as compressed samples, rather
/// than re-encoded: nothing here would improve it, and passthrough cannot
/// degrade it. A track the `.mov` container will not take is dropped rather
/// than failing the import.
public func transcodeToHEVC(
    source: URL,
    destination: URL,
    halveFrameRate: Bool = false
) throws -> TranscodeResult {
    let asset = AVURLAsset(url: source)

    // Load the video track (async API bridged for CLI use).
    var loadedTrack: AVAssetTrack?
    var loadError: Error?
    let loadDone = DispatchSemaphore(value: 0)
    asset.loadTracks(withMediaType: .video) { tracks, error in
        loadedTrack = tracks?.first
        loadError = error
        loadDone.signal()
    }
    loadDone.wait()
    if let error = loadError { throw TranscodeError.readerFailed("\(error)") }
    guard let track = loadedTrack else { throw TranscodeError.noVideoTrack }

    let audioTrack = firstAudioTrack(of: asset)

    let transformedSize = track.naturalSize.applying(track.preferredTransform)
    let width = Int(abs(transformedSize.width).rounded())
    let height = Int(abs(transformedSize.height).rounded())
    let sourceFPS = Double(track.nominalFrameRate)
    let outputFPS = halveFrameRate ? sourceFPS / 2 : sourceFPS
    let duration = CMTimeGetSeconds(track.timeRange.duration)

    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
    )
    readerOutput.alwaysCopiesSampleData = false
    reader.add(readerOutput)

    // `nil` output settings on both sides means the compressed samples are
    // handed over as they are, with no decode and no encode.
    var audioOutput: AVAssetReaderTrackOutput?
    if let audioTrack {
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        if reader.canAdd(output) {
            reader.add(output)
            audioOutput = output
        }
    }

    try? FileManager.default.removeItem(at: destination)
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    // Put the moov atom at the FRONT of the file. A player needs that index
    // before it can decode anything, so without this a streamed wallpaper has
    // to pull the whole file before the first frame appears.
    writer.shouldOptimizeForNetworkUse = true
    let compression: [String: Any] = [
        AVVideoAverageBitRateKey: recommendedBitrate(width: width, height: height, fps: outputFPS),
        AVVideoExpectedSourceFrameRateKey: Int(outputFPS.rounded()),
        AVVideoMaxKeyFrameIntervalKey: max(1, Int(outputFPS.rounded()) * 2),
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
    ]
    let writerInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
    )
    writerInput.expectsMediaDataInRealTime = false
    writerInput.transform = track.preferredTransform
    writer.add(writerInput)

    var audioInput: AVAssetWriterInput?
    if audioOutput != nil {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        input.expectsMediaDataInRealTime = false
        if writer.canAdd(input) {
            writer.add(input)
            audioInput = input
        } else {
            audioOutput = nil
        }
    }

    guard reader.startReading() else {
        throw TranscodeError.readerFailed(reader.error.map { "\($0)" } ?? "unknown")
    }
    guard writer.startWriting() else {
        throw TranscodeError.writerFailed(writer.error.map { "\($0)" } ?? "unknown")
    }

    let queue = DispatchQueue(label: "muro.transcode")
    let copyDone = DispatchSemaphore(value: 0)
    var frameIndex = 0
    // The video pump decides when the session starts, and the audio pump has
    // to wait for it: a sample appended before the session, or earlier than
    // its start time, is rejected. Two queues, so one lock rather than none.
    let session = SessionStart()

    writerInput.requestMediaDataWhenReady(on: queue) {
        while writerInput.isReadyForMoreMediaData {
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                writerInput.markAsFinished()
                copyDone.signal()
                return
            }
            if halveFrameRate {
                let keep = frameIndex % 2 == 0
                frameIndex += 1
                if !keep { continue }
            }
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            if session.start(at: presentation, on: writer) {
                // Started by this very sample.
            }
            if !writerInput.append(sample) {
                reader.cancelReading()
                writerInput.markAsFinished()
                copyDone.signal()
                return
            }
        }
    }

    let audioDone = DispatchSemaphore(value: 0)
    if let audioInput, let audioOutput {
        let audioQueue = DispatchQueue(label: "muro.transcode.audio")
        audioInput.requestMediaDataWhenReady(on: audioQueue) {
            while audioInput.isReadyForMoreMediaData {
                guard let began = session.waitForStart(while: reader) else {
                    audioInput.markAsFinished()
                    audioDone.signal()
                    return
                }
                guard let sample = audioOutput.copyNextSampleBuffer() else {
                    audioInput.markAsFinished()
                    audioDone.signal()
                    return
                }
                if CMSampleBufferGetPresentationTimeStamp(sample) < began { continue }
                if !audioInput.append(sample) {
                    // The container refused the track. The picture is what
                    // matters, so finish without it rather than fail.
                    audioInput.markAsFinished()
                    audioDone.signal()
                    return
                }
            }
        }
    } else {
        audioDone.signal()
    }

    copyDone.wait()
    audioDone.wait()

    if reader.status == .failed {
        throw TranscodeError.readerFailed(reader.error.map { "\($0)" } ?? "unknown")
    }

    let finishDone = DispatchSemaphore(value: 0)
    writer.finishWriting { finishDone.signal() }
    finishDone.wait()
    guard writer.status == .completed else {
        throw TranscodeError.writerFailed(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")
    }
    removeSafeSaveLeftovers(for: destination)

    return TranscodeResult(
        width: width, height: height, fps: outputFPS, duration: duration,
        hasAudio: audioInput != nil && hasAudioTrack(at: destination)
    )
}

/// When the writer's session began, shared by the video and audio pumps.
private final class SessionStart {
    private let lock = NSLock()
    private var time: CMTime?

    /// Starts the session at `time` if it has not started. True when this call
    /// is what started it.
    @discardableResult
    func start(at time: CMTime, on writer: AVAssetWriter) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.time == nil else { return false }
        writer.startSession(atSourceTime: time)
        self.time = time
        return true
    }

    private var started: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    /// Blocks until the video pump has started the session, or until the read
    /// has clearly stopped, in which case there is nothing to wait for and
    /// this returns nil.
    func waitForStart(while reader: AVAssetReader) -> CMTime? {
        while true {
            if let started { return started }
            if reader.status == .failed || reader.status == .cancelled || reader.status == .completed {
                return started
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

/// Whether a finished file really ended up with audio, rather than whether one
/// was attempted. The difference is a track the container quietly refused.
private func hasAudioTrack(at url: URL) -> Bool {
    firstAudioTrack(of: AVURLAsset(url: url)) != nil
}

/// The asset's first audio track, loaded synchronously.
private func firstAudioTrack(of asset: AVURLAsset) -> AVAssetTrack? {
    var track: AVAssetTrack?
    let done = DispatchSemaphore(value: 0)
    asset.loadTracks(withMediaType: .audio) { tracks, _ in
        track = tracks?.first
        done.signal()
    }
    done.wait()
    return track
}

/// With `shouldOptimizeForNetworkUse`, AVAssetWriter produces the faststart
/// file via a safe-save sibling (`<name>.sb-…`) that macOS 27 sometimes fails
/// to delete — one stray temp per encode, silently doubling disk use. Sweep
/// them after every successful write.
func removeSafeSaveLeftovers(for destination: URL) {
    let dir = destination.deletingLastPathComponent()
    let prefix = destination.lastPathComponent + ".sb-"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
    for name in names where name.hasPrefix(prefix) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

/// Bitrate heuristic for HEVC wallpaper loops: ~0.045 bits/pixel/frame,
/// clamped to a sane range. 4K@30 ≈ 11 Mbps, 4K@60 ≈ 22 Mbps, 1080p@30 ≈ 3 Mbps.
func recommendedBitrate(width: Int, height: Int, fps: Double) -> Int {
    let bitsPerSecond = Double(width * height) * fps * 0.045
    return max(3_000_000, min(Int(bitsPerSecond), 25_000_000))
}

/// Brings a video into the library **without re-encoding a single frame**.
///
/// `transcodeToHEVC` decodes every frame and encodes it again at a bitrate
/// `recommendedBitrate` chooses. That is a second generation of lossy
/// compression on top of whatever the source already went through, and it is
/// where quality was being lost: a 40 Mbps 4K master came out the far side at
/// the 25 Mbps ceiling, and even a clip well under the ceiling still paid for
/// one more encode.
///
/// This copies the compressed samples across instead, so the picture that
/// lands in the library is the picture that was handed in, to the bit. What
/// still happens is everything around the video: the container becomes `.mov`
/// like every other master, and `moov` goes to the front so the file streams.
/// An audio track comes across untouched as well, and is dropped only if the
/// export refuses it, in which case the video alone is exported again.
///
/// It goes through a composition holding only the video track, exported with
/// the passthrough preset. Copying the samples by hand with a reader and a
/// writer looks simpler and is not: the reader hands back the first sample of
/// a file with an edit list carrying **no** presentation timestamp, which
/// crashes `startSession` outright, and writing it at the session start
/// instead puts a junk frame at time zero that renders black. Both showed up
/// on real clips. A composition makes AVFoundation own that timing, which it
/// gets right.
///
/// The cost is size. An H.264 source stays H.264 sized rather than shrinking
/// into HEVC, which is the trade the owner asked for: original quality first,
/// a smaller file only if it costs nothing to look at.
@discardableResult
public func copyVideoStream(source: URL, destination: URL) throws -> TranscodeResult {
    let asset = AVURLAsset(url: source)

    var loadedTrack: AVAssetTrack?
    var loadError: Error?
    let loadDone = DispatchSemaphore(value: 0)
    asset.loadTracks(withMediaType: .video) { tracks, error in
        loadedTrack = tracks?.first
        loadError = error
        loadDone.signal()
    }
    loadDone.wait()
    if let error = loadError { throw TranscodeError.readerFailed("\(error)") }
    guard let track = loadedTrack else { throw TranscodeError.noVideoTrack }

    let transformedSize = track.naturalSize.applying(track.preferredTransform)
    let width = Int(abs(transformedSize.width).rounded())
    let height = Int(abs(transformedSize.height).rounded())
    let fps = Double(track.nominalFrameRate)
    let duration = CMTimeGetSeconds(track.timeRange.duration)

    let composition = AVMutableComposition()
    guard let videoTrack = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
        throw TranscodeError.writerFailed("could not add a video track")
    }
    do {
        try videoTrack.insertTimeRange(track.timeRange, of: track, at: .zero)
    } catch {
        throw TranscodeError.readerFailed("\(error)")
    }
    videoTrack.preferredTransform = track.preferredTransform

    // The source's own sound, when it has any. Inserted best effort: a track
    // that will not insert is one the export would not have taken either.
    var audioComposed: AVMutableCompositionTrack?
    if let sourceAudio = firstAudioTrack(of: asset),
       let compositionAudio = composition.addMutableTrack(
           withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
       ) {
        if (try? compositionAudio.insertTimeRange(sourceAudio.timeRange, of: sourceAudio, at: .zero)) != nil {
            audioComposed = compositionAudio
        } else {
            composition.removeTrack(compositionAudio)
        }
    }

    do {
        try passthroughExport(composition, to: destination)
    } catch {
        // Passthrough cannot re-encode, so a codec the `.mov` container will
        // not carry fails the whole export. The picture is what a wallpaper
        // is; going again without the sound beats refusing the import.
        guard let audioComposed else { throw error }
        composition.removeTrack(audioComposed)
        try passthroughExport(composition, to: destination)
        removeSafeSaveLeftovers(for: destination)
        return TranscodeResult(width: width, height: height, fps: fps, duration: duration, hasAudio: false)
    }
    removeSafeSaveLeftovers(for: destination)

    return TranscodeResult(
        width: width, height: height, fps: fps, duration: duration,
        hasAudio: audioComposed != nil && hasAudioTrack(at: destination)
    )
}

private func passthroughExport(_ asset: AVAsset, to destination: URL) throws {
    guard let export = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetPassthrough
    ) else {
        throw TranscodeError.writerFailed("no passthrough export session")
    }
    try? FileManager.default.removeItem(at: destination)
    export.outputURL = destination
    export.outputFileType = .mov
    // The moov atom belongs at the front, or a player has to pull the whole
    // file before it can show anything.
    export.shouldOptimizeForNetworkUse = true

    let exportDone = DispatchSemaphore(value: 0)
    export.exportAsynchronously { exportDone.signal() }
    exportDone.wait()

    guard export.status == .completed else {
        throw TranscodeError.writerFailed(
            export.error.map { "\($0)" } ?? "status \(export.status.rawValue)"
        )
    }
}
