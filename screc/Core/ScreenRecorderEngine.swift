import AVFoundation
import AppKit
import QuartzCore
@preconcurrency import ScreenCaptureKit

enum CaptureTarget {
    case window(SCWindow)
    case display(SCDisplay)
    /// Rect is display-local, top-left origin, in points — the
    /// `SCStreamConfiguration.sourceRect` convention.
    case region(SCDisplay, CGRect)
    /// "Record specific window": the window is composited ALONE onto its
    /// display (overlapping windows never appear) and `sourceRect` crops the
    /// remembered sub-area. A display-style filter is required because
    /// window-style filters ignore `sourceRect`, and it also survives the
    /// window closing (the stream keeps running; we pause appends instead).
    case pinned(SCWindow, SCDisplay, CGRect)
    /// Debug mode: no ScreenCaptureKit at all — black frames at this size,
    /// so the whole encode/stats/convert path can be exercised without the
    /// screen-recording permission. Size is in points.
    case synthetic(CGSize)
}

/// ScreenCaptureKit → AVAssetWriter live-encode engine. ScreenCaptureKit
/// downscales on the GPU to the preset's output size and VideoToolbox
/// hardware-encodes at the preset's bitrate while recording — the file is
/// share-ready the moment `stop()` returns. No post-processing step exists.
/// The preset resolution is a MAXIMUM: content whose native pixel size is
/// smaller records at exactly its native size (never upscaled).
///
/// Threading: SCK delivers samples on `sampleQueue`; the heartbeat and stats
/// timers run there too, so everything below the "sampleQueue-confined" marker
/// is queue-confined. `stop()` synchronizes onto the queue before finalizing.
/// `@unchecked Sendable` is backed by that discipline.
final class ScreenRecorderEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    var onStatsUpdate: (@MainActor @Sendable (RecordingStats) -> Void)?
    /// Fired when the system ends the stream (recorded window closed in
    /// window mode, user stopped via the system's capture indicator, display
    /// gone).
    var onAutoStop: (@MainActor @Sendable (Error) -> Void)?

    private let target: CaptureTarget
    private let config: RecordingConfig
    private let outputURL: URL
    private let wantsAudio: Bool
    private let showsCursor: Bool
    /// Microphone rides the same SCStream (SCK captures it natively on
    /// macOS 15) and lands in a SEPARATE track; AppState mixes it down after
    /// stop. True only with the feature enabled AND the permission granted.
    let capturesMic: Bool
    private let micDeviceID: String

    private var fps: Int { config.maxFPS }
    /// Whether a system-audio track is being written (mix-down needs to know
    /// which tracks exist and in what order).
    var capturesSystemAudio: Bool { wantsAudio }

    private let sampleQueue = DispatchQueue(label: "com.holzschneider.screc.capture")

    private var stream: SCStream?
    private var streamConfig: SCStreamConfiguration?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var startDate = Date()

    // MARK: sampleQueue-confined state
    private var sessionStarted = false
    private var finishing = false
    private var paused = false
    /// Total paused time, subtracted from every PTS after a resume so pauses
    /// become clean cuts instead of frozen segments.
    private var pauseOffset = CMTime.zero
    private var pauseBeganHost: CMTime?
    private var pausedWallAccum: TimeInterval = 0
    private var pauseBeganWall: Date?
    private var lastVideoBuffer: CMSampleBuffer?
    private var lastArrivalTime: CFTimeInterval = 0
    /// PTS of the last frame handed to the writer. The writer requires
    /// strictly increasing presentation times; one violation fails it and
    /// loses the whole take, so anything at or before this is dropped.
    private var lastVideoPTS = CMTime.invalid
    /// The session's start time (first video frame). Audio that precedes it
    /// would fall outside the session and produce a warning edit at the file
    /// head — dropped instead.
    private var sessionStartPTS = CMTime.zero
    private var framesSinceTick = 0
    private var framesDropped = 0
    private var heartbeat: DispatchSourceTimer?
    private var statsTicker: DispatchSourceTimer?
    private var syntheticTicker: DispatchSourceTimer?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var syntheticFrame: Int64 = 0

    @MainActor
    init(target: CaptureTarget, config: RecordingConfig, outputURL: URL) {
        self.target = target
        self.config = config
        self.outputURL = outputURL
        self.wantsAudio = config.format != .gif
            && config.audioBitrateKbps > 0
            && Prefs.captureSystemAudio
        self.showsCursor = Prefs.showsCursor
        var mic = false
        if case .synthetic = target {
            mic = false // debug mode has no SCStream to carry the mic
        } else if config.format != .gif, Prefs.micEnabled {
            mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if Prefs.micEnabled, !mic {
                Log.engine.notice("mic enabled but permission not granted — recording without it")
            }
        }
        self.capturesMic = mic
        self.micDeviceID = Prefs.micDeviceID
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        if case .synthetic(let points) = target {
            try startSynthetic(points: points)
            return
        }
        let filter = try await makeFilter()
        let contentPoints: CGSize
        switch target {
        case .region(_, let rect), .pinned(_, _, let rect):
            contentPoints = rect.size
        case .window, .display:
            contentPoints = filter.contentRect.size
        case .synthetic(let size):
            contentPoints = size
        }
        let (width, height) = Self.outputPixelSize(
            contentPoints: contentPoints,
            scale: CGFloat(filter.pointPixelScale),
            maxWidth: config.maxWidth,
            maxHeight: config.maxHeight)

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        streamConfig.queueDepth = 5
        streamConfig.showsCursor = showsCursor
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.scalesToFit = true
        switch target {
        case .window:
            streamConfig.ignoreShadowsSingleWindow = true
        case .region(_, let rect), .pinned(_, _, let rect):
            streamConfig.sourceRect = rect
        case .display, .synthetic:
            break
        }
        if wantsAudio {
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.sampleRate = 48_000
            // Match the writer's channel layout so no downmix is needed.
            streamConfig.channelCount = config.audioChannels == 1 ? 1 : 2
        }
        if capturesMic {
            streamConfig.captureMicrophone = true
            if !micDeviceID.isEmpty {
                streamConfig.microphoneCaptureDeviceID = micDeviceID
            }
        }

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // GIF records an intermediate H.264 master at a fixed healthy bitrate;
        // the conversion step decides the final look.
        let videoBitrate = config.format == .gif ? 1_500_000 : config.videoBitrateKbps * 1000
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            // Long GOP: screen content is mostly static.
            AVVideoMaxKeyFrameIntervalKey: fps * max(config.keyframeSeconds, 1),
            AVVideoAllowFrameReorderingKey: config.allowBFrames,
        ]
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        switch config.format {
        case .hevc:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
        case .mp4, .gif:
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.h264
            compression[AVVideoProfileLevelKey] = switch config.h264Profile {
            case "baseline": AVVideoProfileLevelH264BaselineAutoLevel
            case "main": AVVideoProfileLevelH264MainAutoLevel
            default: AVVideoProfileLevelH264HighAutoLevel
            }
            // CABAC requires Main/High profile.
            if config.h264CABAC, config.h264Profile != "baseline" {
                compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
        }
        videoSettings[AVVideoCompressionPropertiesKey] = compression

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScrecError.writerFailed("video settings rejected (\(width)×\(height))")
        }
        writer.add(videoInput)

        if wantsAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: config.audioChannels == 1 ? 1 : 2,
                AVEncoderBitRateKey: config.audioBitrateKbps * 1000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        if capturesMic {
            // Intermediate voice track (mono AAC); the post-stop mix-down
            // decodes it again, applies the gain slider, and folds it into
            // the system-audio track.
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                micInput = input
            }
        }

        guard writer.startWriting() else {
            throw ScrecError.writerFailed(writer.error?.localizedDescription ?? "could not start writing")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.streamConfig = streamConfig
        self.startDate = Date()

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if wantsAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if capturesMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream
        sampleQueue.sync {} // publish writer/inputs to the queue before frames arrive
        try await stream.startCapture()
        startTimers()
    }

    /// Stops capture and finalizes the file (moov atom). The file must not be
    /// surfaced before this returns. Also reports the recorded duration
    /// (pauses excluded) so callers can discard too-short takes.
    func stop() async throws -> (url: URL, duration: TimeInterval) {
        // Swallow "already stopped" — the auto-stop path arrives here after
        // the system has torn the stream down.
        if let stream {
            try? await stream.stopCapture()
        }
        var hadFrames = false
        var duration: TimeInterval = 0
        sampleQueue.sync {
            finishing = true
            syntheticTicker?.cancel()
            syntheticTicker = nil
            heartbeat?.cancel()
            heartbeat = nil
            statsTicker?.cancel()
            statsTicker = nil
            hadFrames = sessionStarted
            duration = Date().timeIntervalSince(startDate) - pausedWallAccum
            if paused, let beganWall = pauseBeganWall {
                duration -= Date().timeIntervalSince(beganWall)
            }
        }
        guard let writer else {
            throw ScrecError.writerFailed("no active writer")
        }
        guard hadFrames else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw ScrecError.nothingCaptured
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw ScrecError.writerFailed(writer.error?.localizedDescription ?? "unknown encoder failure")
        }
        return (outputURL, max(duration, 0))
    }

    // MARK: - Live control (pinned mode & follow-focus)

    /// Follow-focus (window mode only): retarget the live stream to another
    /// window. Output size stays fixed; SCK letterboxes via `scalesToFit`.
    /// Called synchronously from the main actor; SCK synchronizes internally.
    func switchToWindow(_ window: SCWindow) {
        guard case .window = target, let stream else { return }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        stream.updateContentFilter(filter) { error in
            if let error {
                Log.engine.error("switchToWindow failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pinned mode: the window moved/resized on the same display — track the
    /// sub-area by moving `sourceRect`.
    func updatePinnedGeometry(sourceRect: CGRect) {
        guard case .pinned = target, let stream, let config = streamConfig else { return }
        config.sourceRect = sourceRect
        stream.updateConfiguration(config) { error in
            if let error {
                Log.engine.error("sourceRect update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pinned mode: the window returned (possibly as a NEW window of a
    /// restarted process) or moved to another display.
    func retarget(window: SCWindow, display: SCDisplay, sourceRect: CGRect) {
        guard case .pinned = target, let stream, let config = streamConfig else { return }
        let filter = SCContentFilter(display: display, including: [window])
        stream.updateContentFilter(filter) { error in
            if let error {
                Log.engine.error("retarget filter failed: \(error.localizedDescription)")
            }
        }
        config.sourceRect = sourceRect
        stream.updateConfiguration(config) { error in
            if let error {
                Log.engine.error("retarget config failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pinned mode: window vanished — halt appends. The stream keeps running;
    /// the pause becomes a clean cut via PTS retiming on resume.
    func pause() {
        sampleQueue.async { [self] in
            guard !paused, !finishing else { return }
            paused = true
            pauseBeganHost = CMClockGetTime(CMClockGetHostTimeClock())
            pauseBeganWall = Date()
        }
    }

    func resume() {
        sampleQueue.async { [self] in
            guard paused else { return }
            paused = false
            if let began = pauseBeganHost {
                pauseOffset = CMTimeAdd(pauseOffset,
                                        CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), began))
            }
            if let beganWall = pauseBeganWall {
                pausedWallAccum += Date().timeIntervalSince(beganWall)
            }
            pauseBeganHost = nil
            pauseBeganWall = nil
        }
    }

    // MARK: - Synthetic capture (debug mode)

    /// Drives the real writer with black frames on a timer, so everything
    /// downstream — encoding, live stats, finalization, GIF conversion —
    /// behaves exactly as in a real recording.
    private func startSynthetic(points: CGSize) throws {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let (width, height) = Self.outputPixelSize(
            contentPoints: points, scale: scale,
            maxWidth: config.maxWidth, maxHeight: config.maxHeight)

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        var videoSettings: [String: Any] = [
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.videoBitrateKbps * 1000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * max(config.keyframeSeconds, 1),
            ],
        ]
        videoSettings[AVVideoCodecKey] = config.format == .hevc
            ? AVVideoCodecType.hevc : AVVideoCodecType.h264

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScrecError.writerFailed("video settings rejected (\(width)×\(height))")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        guard writer.startWriting() else {
            throw ScrecError.writerFailed(
                writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.pixelAdaptor = adaptor
        self.startDate = Date()
        sampleQueue.sync {
            sessionStarted = true
            syntheticFrame = 0
        }

        let ticker = DispatchSource.makeTimerSource(queue: sampleQueue)
        ticker.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        ticker.setEventHandler { [weak self] in self?.appendSyntheticFrame() }
        ticker.resume()
        syntheticTicker = ticker
        startStatsTicker()
    }

    private func appendSyntheticFrame() {
        guard !finishing, !paused,
              let videoInput, videoInput.isReadyForMoreMediaData,
              let pool = pixelAdaptor?.pixelBufferPool
        else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer
        else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            // Opaque black: BGRA zeroed, alpha forced on.
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
            for offset in stride(from: 3, to: count, by: 4) { pixels[offset] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let pts = CMTime(value: syntheticFrame, timescale: CMTimeScale(fps))
        pixelAdaptor?.append(buffer, withPresentationTime: pts)
        syntheticFrame += 1
        framesSinceTick += 1
    }

    // MARK: - Setup helpers

    private func makeFilter() async throws -> SCContentFilter {
        switch target {
        case .window(let window):
            // Follows the window across Spaces and displays.
            return SCContentFilter(desktopIndependentWindow: window)
        case .pinned(let window, let display, _):
            return SCContentFilter(display: display, including: [window])
        case .synthetic:
            throw ScrecError.writerFailed("synthetic target has no filter")
        case .display(let display), .region(let display, _):
            let content = try await SCShareableContent
                .excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ownApps = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            return SCContentFilter(display: display,
                                   excludingApplications: ownApps,
                                   exceptingWindows: [])
        }
    }

    /// See OutputSizing.pixelSize — extracted so the unit tests can compile
    /// the math without the ScreenCaptureKit dependency chain.
    static func outputPixelSize(contentPoints: CGSize, scale: CGFloat,
                                maxWidth: Int?, maxHeight: Int?) -> (Int, Int) {
        OutputSizing.pixelSize(contentPoints: contentPoints, scale: scale,
                               maxWidth: maxWidth, maxHeight: maxHeight)
    }

    private func startStatsTicker() {
        sampleQueue.async { [self] in
            guard statsTicker == nil else { return }
            let st = DispatchSource.makeTimerSource(queue: sampleQueue)
            st.schedule(deadline: .now() + 1, repeating: 1)
            st.setEventHandler { [weak self] in self?.statsTick() }
            st.resume()
            statsTicker = st
        }
    }

    private func startTimers() {
        sampleQueue.async { [self] in
            let hb = DispatchSource.makeTimerSource(queue: sampleQueue)
            hb.schedule(deadline: .now() + 1, repeating: 1)
            hb.setEventHandler { [weak self] in self?.heartbeatTick() }
            hb.resume()
            heartbeat = hb

            let st = DispatchSource.makeTimerSource(queue: sampleQueue)
            st.schedule(deadline: .now() + 1, repeating: 1)
            st.setEventHandler { [weak self] in self?.statsTick() }
            st.resume()
            statsTicker = st
        }
    }

    // MARK: - Sample handling (sampleQueue)

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard !finishing, !paused, sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer, into: audioInput)
        case .microphone: handleAudio(sampleBuffer, into: micInput)
        default: break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // SCK marks idle/blank frames; only .complete carries new content.
        guard let attachments = (CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let statusValue = attachments[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let writer, let videoInput
        else { return }

        var buffer = sampleBuffer
        if pauseOffset != .zero, let shifted = Self.retimed(sampleBuffer, by: pauseOffset) {
            buffer = shifted
        }
        if !sessionStarted {
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            sessionStartPTS = buffer.presentationTimeStamp
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else {
            framesDropped += 1
            return
        }
        let pts = buffer.presentationTimeStamp
        guard !lastVideoPTS.isValid || pts > lastVideoPTS else {
            // A real frame racing a just-appended heartbeat copy can arrive
            // marginally in the past. Keep its (newer) content for future
            // heartbeats, but never hand the writer a non-increasing PTS.
            lastVideoBuffer = buffer
            lastArrivalTime = CACurrentMediaTime()
            return
        }
        videoInput.append(buffer)
        lastVideoPTS = pts
        lastVideoBuffer = buffer
        lastArrivalTime = CACurrentMediaTime()
        framesSinceTick += 1
    }

    /// Shared by the system-audio and microphone tracks.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer, into input: AVAssetWriterInput?) {
        // Audio before the first video frame would precede the session start.
        guard sessionStarted,
              let input, input.isReadyForMoreMediaData
        else { return }
        var buffer = sampleBuffer
        if pauseOffset != .zero, let shifted = Self.retimed(sampleBuffer, by: pauseOffset) {
            buffer = shifted
        }
        guard buffer.presentationTimeStamp >= sessionStartPTS else { return }
        input.append(buffer)
    }

    /// SCK is damage-driven: a static screen delivers no frames, which would
    /// make the file end at the last change. Re-append the last frame during
    /// idle gaps so video duration tracks wall time (SCK frame PTS and the
    /// host clock share a time domain).
    private func heartbeatTick() {
        guard sessionStarted, !finishing, !paused,
              let last = lastVideoBuffer,
              let videoInput, videoInput.isReadyForMoreMediaData,
              CACurrentMediaTime() - lastArrivalTime > 1.2
        else { return }
        let pts = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), pauseOffset)
        if lastVideoPTS.isValid, pts <= lastVideoPTS { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: last,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &copy) == noErr,
              let copy
        else { return }
        videoInput.append(copy)
        lastVideoPTS = pts
    }

    private static func retimed(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: CMTimeSubtract(
                CMSampleBufferGetPresentationTimeStamp(sample), offset),
            decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sample,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &copy) == noErr
        else { return nil }
        return copy
    }

    private func statsTick() {
        var stats = RecordingStats()
        var duration = Date().timeIntervalSince(startDate) - pausedWallAccum
        if paused, let beganWall = pauseBeganWall {
            duration -= Date().timeIntervalSince(beganWall)
        }
        stats.duration = max(duration, 0)
        stats.framesPerSecond = Double(framesSinceTick) // 1 s cadence
        stats.framesDropped = framesDropped
        stats.isPaused = paused
        framesSinceTick = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let bytes = (attributes[.size] as? NSNumber)?.int64Value {
            stats.bytesWritten = bytes
        }
        let snapshot = stats
        Task { @MainActor [onStatsUpdate] in
            onStatsUpdate?(snapshot)
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [onAutoStop] in
            onAutoStop?(error)
        }
    }
}
